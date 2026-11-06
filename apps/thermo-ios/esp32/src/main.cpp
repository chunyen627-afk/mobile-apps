#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <WiFiManager.h>
#include <NimBLEDevice.h>
#include <esp32-hal-alloc-ble-mem.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <esp_timer.h>
#include <esp_system.h>
#include <esp_ota_ops.h>
#include <time.h>
#include "core.h"
#include "display.h"

using namespace thermo;
constexpr unsigned MAX_SENSORS=4;
constexpr uint32_t FRESH_SECONDS=300;
Display lcd;
lgfx::LGFX_Sprite uiLine(&lcd);
bool uiLineReady=false;
String uiText[9];uint16_t uiColor[9]={};
int uiLayout=-1;
bool displayAwake=true,touchHeld=false;
uint64_t displayActiveUs=0;
constexpr uint64_t DISPLAY_TIMEOUT_US=10000000;
WebServer http(18787);
WiFiManager wifiManager;
Preferences preferences;
QueueHandle_t packets;
NimBLEScan* scanner;
bool fsOK=false, dirty=false, httpStarted=false, portal=false;
bool inverted=false;
String apName,apPassword,sourceId;
uint32_t bootId, packetCount=0, queueDrops=0, unknownDropped=0;
uint64_t lastUI=0,lastLog=0,lastWiFiAttempt=0,lastTouch=0,lastStateSave=0;
uint64_t wifiStartedUs=0;
int page=0;
struct Sensor {
  String id, base, advertised, label, room;
  Reading reading;
  int rssi=0;
  int64_t updated=0, heardUs=0;
  bool heard=false;
};
Sensor sensors[MAX_SENSORS]; unsigned sensorCount=0;
struct Packet { char mac[18],name[40]; Reading reading; int rssi; int64_t us; };
class Advertisements : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice* d) override {
    for(unsigned i=0;i<d->getServiceDataCount();++i) {
      auto uuid=d->getServiceDataUUID(i);
      uint16_t u=uuid==NimBLEUUID(uint16_t(0xFCD2))?0xFCD2:
        uuid==NimBLEUUID(uint16_t(0x181A))?0x181A:0;
      if(!u) continue;
      std::string data=d->getServiceData(i);
      Reading r=decode(u,reinterpret_cast<const uint8_t*>(data.data()),data.size());
      if(!r.fields) continue;
      Packet p={}; snprintf(p.mac,sizeof(p.mac),"%s",d->getAddress().toString().c_str());
      if(d->haveName()) snprintf(p.name,sizeof(p.name),"%s",d->getName().c_str());
      p.reading=r; p.rssi=d->getRSSI(); p.us=esp_timer_get_time();
      if(xQueueSend(packets,&p,0)!=pdTRUE) __atomic_fetch_add(&queueDrops,1,__ATOMIC_RELAXED);
      break;
    }
  }
} callbacks;
int64_t nowSeconds() { time_t t=time(nullptr); return t>1700000000 ? int64_t(t):0; }
String normalize(String s) {s.trim();s.toUpperCase();s.replace('-',':');return s;}
int findSensor(const String& id) {for(unsigned i=0;i<sensorCount;++i) if(sensors[i].id==id)return i;return -1;}
String displayName(const Sensor& s) {return s.label.length()?s.label:s.base.length()?s.base:s.id;}
// Python strips Unicode whitespace and truncates by code points, not UTF-8 bytes.
bool whitespace(uint32_t c) {return (c>=9&&c<=13)||(c>=0x1c&&c<=0x20)||c==0x85||c==0xa0||c==0x1680||
  (c>=0x2000&&c<=0x200a)||c==0x2028||c==0x2029||c==0x202f||c==0x205f||c==0x3000;}
String labelText(String s) {
  size_t start=0,end=0,i=0; bool found=false;
  while(i<s.length()) {size_t b=i;uint32_t c=uint8_t(s[i++]);unsigned n=0;
    if(c>=0xf0){c&=7;n=3;}else if(c>=0xe0){c&=15;n=2;}else if(c>=0xc0){c&=31;n=1;}
    while(n--&&i<s.length())c=(c<<6)|(uint8_t(s[i++])&63);
    if(!whitespace(c)){if(!found)start=b;found=true;end=i;}
  }
  if(!found)return "";
  unsigned count=0; i=start;
  while(i<end && count<40){++i;while(i<end&&(uint8_t(s[i])&0xc0)==0x80)++i;++count;}
  return s.substring(start,i);
}
void nullable(JsonObject o,const char* key,const String& s) {if(s.length())o[key]=s;else o[key]=nullptr;}
void sensorJSON(JsonObject o,const Sensor& s) {
  o["id"]=s.id;o["name"]=displayName(s);nullable(o,"label",s.label);nullable(o,"room",s.room);
  nullable(o,"advertised_name",s.advertised);
  if(s.reading.fields&TEMP)o["temperature"]=s.reading.temperature;else o["temperature"]=nullptr;
  if(s.reading.fields&HUM)o["humidity"]=s.reading.humidity;else o["humidity"]=nullptr;
  if(s.reading.fields&BATT)o["battery"]=s.reading.battery;else o["battery"]=nullptr;
  if(s.reading.fields&VOLT)o["voltage"]=s.reading.voltage;else o["voltage"]=nullptr;
  if(s.updated)o["updated"]=s.updated;else o["updated"]=nullptr;
  if(s.reading.fields)o["rssi"]=s.rssi;else o["rssi"]=nullptr;
  if(s.reading.format)o["format"]=s.reading.format;else o["format"]=nullptr;
  o["error"]=nullptr;
}
bool saveState() {
  if(!fsOK)return false;
  DynamicJsonDocument doc(16384);JsonArray a=doc.createNestedArray("sensors");
  for(unsigned i=0;i<sensorCount;++i){auto o=a.createNestedObject();sensorJSON(o,sensors[i]);o["base"]=sensors[i].base;}
  File f=LittleFS.open("/state.tmp","w");if(!f)return false;
  size_t expect=measureJson(doc);size_t wrote=serializeJson(doc,f);f.flush();f.close();
  if(doc.overflowed()||wrote!=expect)return false;
  // Keep a fallback in case a reset interrupts a rename.
  if(LittleFS.exists("/state.json")){
    LittleFS.remove("/state.bak");if(!LittleFS.rename("/state.json","/state.bak"))return false;
  }
  if(!LittleFS.rename("/state.tmp","/state.json"))return false;
  dirty=false;lastStateSave=esp_timer_get_time();return true;
}
void loadState() {
  DynamicJsonDocument doc(16384);
  for(const char* path:{"/state.json","/state.bak"}) {
    File f=LittleFS.open(path,"r");if(!f)continue;
    auto err=deserializeJson(doc,f);f.close();if(!err&&doc["sensors"].is<JsonArray>())break;doc.clear();
  }
  for(JsonObject o:doc["sensors"].as<JsonArray>()) {
    if(sensorCount>=MAX_SENSORS)break;
    Sensor& s=sensors[sensorCount++];s.id=normalize(o["id"].as<String>());
    s.base=o["base"]|"";s.label=o["label"]|"";s.room=o["room"]|"";
    s.advertised=o["advertised_name"]|"";s.updated=o["updated"]|int64_t(0);s.rssi=o["rssi"]|0;
    if(!o["temperature"].isNull()){s.reading.temperature=o["temperature"];s.reading.fields|=TEMP;}
    if(!o["humidity"].isNull()){s.reading.humidity=o["humidity"];s.reading.fields|=HUM;}
    if(!o["battery"].isNull()){s.reading.battery=o["battery"];s.reading.fields|=BATT;}
    if(!o["voltage"].isNull()){s.reading.voltage=o["voltage"];s.reading.fields|=VOLT;}
    String fmt=o["format"].as<String>();s.reading.format=fmt=="bthome"?"bthome":fmt=="pvvx"?"pvvx":fmt=="atc1441"?"atc1441":nullptr;
  }
}
void drainPackets() {
  Packet p;
  while(xQueueReceive(packets,&p,0)==pdTRUE) {
    String id=normalize(p.mac);int idx=findSensor(id);
    if(idx<0){if(sensorCount==MAX_SENSORS){++unknownDropped;continue;}idx=sensorCount++;
      sensors[idx].id=id;sensors[idx].base=p.name[0]?String(p.name):id;dirty=true;
    }
    Sensor& s=sensors[idx];merge(s.reading,p.reading);s.rssi=p.rssi;s.heardUs=p.us;s.heard=true;
    int64_t now=nowSeconds();s.updated=now?now-(esp_timer_get_time()-p.us)/1000000:0;
    if(p.name[0]){s.advertised=p.name;if(s.base==id)s.base=p.name;}
    ++packetCount;
  }
}
// Daily append-only frames. CRC protects against an interrupted final write.
struct __attribute__((packed)) Frame {uint16_t magic,slot;uint8_t count,reserved;uint16_t crc;};
uint16_t crc16(const uint8_t* p,size_t n) {uint16_t c=0xffff;while(n--){c^=uint16_t(*p++)<<8;for(int i=0;i<8;++i)c=c&0x8000?(c<<1)^0x1021:c<<1;}return c;}
uint16_t masks[288]={};int64_t loadedDay=-1,lastRecordSlot=-1;
String dayFile(int64_t d){return "/h"+String((long)d)+".bin";}
// Returns false at a damaged/torn frame; earlier complete frames remain usable.
bool readFrame(File& f,Frame& h,Sample* rows) {
  if(f.read(reinterpret_cast<uint8_t*>(&h),sizeof(h))!=sizeof(h))return false;
  if(h.magic!=0x5448||h.slot>=288||!h.count||h.count>MAX_SENSORS)return false;
  size_t n=h.count*sizeof(Sample);
  if(f.read(reinterpret_cast<uint8_t*>(rows),n)!=n||crc16(reinterpret_cast<uint8_t*>(rows),n)!=h.crc)return false;
  for(unsigned i=0;i<h.count;++i)if(rows[i].sensor>=MAX_SENSORS||rows[i].slot!=h.slot)return false;
  return true;
}
bool loadDay(int64_t day) {
  memset(masks,0,sizeof(masks));loadedDay=day;
  String path=dayFile(day);File f=LittleFS.open(path,"r");if(!f)return true;
  size_t valid=0;Frame h;Sample rows[MAX_SENSORS];
  while(readFrame(f,h,rows)){for(unsigned i=0;i<h.count;++i)masks[h.slot]|=1u<<rows[i].sensor;valid=f.position();delay(0);}
  size_t total=f.size();f.close();
  if(valid==total)return true;
  // Recover only this gateway's partial tail without formatting the filesystem.
  File src=LittleFS.open(path,"r"),dst=LittleFS.open("/recover.tmp","w");
  if(!src||!dst)return false;
  uint8_t buf[256];size_t left=valid;bool ok=true;
  while(left){size_t n=std::min(left,sizeof(buf));if(src.read(buf,n)!=n||dst.write(buf,n)!=n){ok=false;break;}left-=n;delay(0);}
  src.close();dst.close();if(!ok)return false;
  return LittleFS.rename("/recover.tmp",path);
}
void pruneHistory(int64_t day) {
  File root=LittleFS.open("/");File f=root.openNextFile();
  while(f){String name=f.name();f.close();if(name.startsWith("/"))name.remove(0,1);
    if(name.startsWith("h")&&name.endsWith(".bin")){int64_t d=name.substring(1,name.length()-4).toInt();
      if(d<day-30)LittleFS.remove("/"+name);}
    f=root.openNextFile();delay(0);
  }root.close();
}
void recordHistory() {
  int64_t now=nowSeconds();if(!now||!fsOK)return;
  int64_t interval=now/300;
  if(interval==lastRecordSlot)return;
  // Match the PC saver: at interval boundary + 1 second; also sample once after first NTP sync.
  int64_t day=(now+UTC_OFFSET)/86400;uint16_t slot=((now+UTC_OFFSET)%86400)/300;
  if(day!=loadedDay){pruneHistory(day);if(!loadDay(day)){Serial.println("HISTORY recovery failed");return;}}
  if(!saveState()){Serial.println("STATE write failed; history deferred");return;}
  Sample rows[MAX_SENSORS];unsigned count=0;
  for(unsigned i=0;i<sensorCount;++i){Sensor& s=sensors[i];
    if(!s.heard||!s.updated||now-s.updated>300||!(s.reading.fields&(TEMP|HUM))||(masks[slot]&(1u<<i)))continue;
    rows[count++]={slot,int16_t(s.reading.fields&TEMP?lround(s.reading.temperature*100):INT16_MIN),
      uint16_t(s.reading.fields&HUM?lround(s.reading.humidity*100):UINT16_MAX),
      uint8_t(s.reading.fields&BATT?s.reading.battery:255),uint8_t(i)};
  }
  if(count){Frame h={0x5448,slot,uint8_t(count),0,crc16(reinterpret_cast<uint8_t*>(rows),count*sizeof(Sample))};
    File f=LittleFS.open(dayFile(day),"a");if(!f){Serial.println("HISTORY open failed");return;}
    bool ok=f.write(reinterpret_cast<const uint8_t*>(&h),sizeof(h))==sizeof(h)&&
      f.write(reinterpret_cast<const uint8_t*>(rows),count*sizeof(Sample))==count*sizeof(Sample);
    f.flush();f.close();if(!ok){loadedDay=-1;Serial.println("HISTORY write failed");return;}
    for(unsigned i=0;i<count;++i)masks[slot]|=1u<<rows[i].sensor;
  }
  lastRecordSlot=interval;Serial.printf("HISTORY t=%lld samples=%u used=%u/%u\n",interval*300,count,LittleFS.usedBytes(),LittleFS.totalBytes());
}
void sendJSON(int status,const JsonDocument& doc) {
  String out;serializeJson(doc,out);http.sendHeader("Cache-Control","no-store");http.send(status,"application/json; charset=utf-8",out);
}
void errorJSON(int status,const char* msg){StaticJsonDocument<128> d;d["error"]=msg;sendJSON(status,d);}
void getSensors(){
  const int64_t now=nowSeconds();
  if(!now){errorJSON(503,"clock not synchronized; retry shortly");return;}
  const int64_t us=esp_timer_get_time();
  // Timestamp samples heard before the first NTP response using the same clock.
  for(unsigned i=0;i<sensorCount;++i)if(sensors[i].heard)
    sensors[i].updated=now-(us-sensors[i].heardUs)/1000000;
  DynamicJsonDocument doc(16384);doc["version"]=1;doc["gateway"]="ESP32 溫濕度閘道";doc["time"]=now;
  auto a=doc.createNestedArray("sensors");unsigned order[MAX_SENSORS];for(unsigned i=0;i<sensorCount;++i)order[i]=i;
  std::sort(order,order+sensorCount,[](unsigned a,unsigned b){String x=displayName(sensors[a]),y=displayName(sensors[b]);x.toLowerCase();y.toLowerCase();return x==y?sensors[a].id<sensors[b].id:x<y;});
  for(unsigned i=0;i<sensorCount;++i)sensorJSON(a.createNestedObject(),sensors[order[i]]);
  doc.createNestedObject("alerts")["enabled"]=false;sendJSON(200,doc);
}
void getHistory(){
  String id=normalize(http.arg("id"));String range=http.hasArg("range")?http.arg("range"):"day";
  int days=range=="day"?1:range=="week"?7:range=="month"?30:0;
  if(!days){errorJSON(400,"range must be day, week or month");return;}
  int idx=findSensor(id);if(idx<0){errorJSON(404,"unknown thermometer");return;}
  int64_t now=nowSeconds();
  if(!now){errorJSON(503,"clock not synchronized; retry shortly");return;}
  int bucket=days==1?1800:86400;
  int64_t start=historyStart(now,days),first=bucketTime(start,bucket);
  Bucket bins[50];for(unsigned i=0;i<50;++i)bins[i].t=first+i*bucket;
  if(fsOK&&now){int64_t today=(now+UTC_OFFSET)/86400;
    for(int64_t day=(start+UTC_OFFSET)/86400;day<=today;++day){
      File f=LittleFS.open(dayFile(day),"r");if(!f)continue;
      Frame h;Sample rows[MAX_SENSORS];uint16_t seen[288]={};unsigned frames=0;
      while(readFrame(f,h,rows)){
        int64_t t=day*86400-UTC_OFFSET+h.slot*300;
        if(t>=start&&t>=now-30*86400){int b=(bucketTime(t,bucket)-first)/bucket;
          if(b>=0&&b<50)for(unsigned i=0;i<h.count;++i){auto& s=rows[i];
            if(s.sensor!=idx||(seen[s.slot]&(1u<<idx)))continue;seen[s.slot]|=1u<<idx;
            Reading r;if(s.temperature!=INT16_MIN){r.fields|=TEMP;r.temperature=s.temperature/100.0;}
            if(s.humidity!=UINT16_MAX){r.fields|=HUM;r.humidity=s.humidity/100.0;}
            if(s.battery!=255){r.fields|=BATT;r.battery=s.battery;}bins[b].add(r);
          }
        }if(++frames%16==0)delay(1);
      }f.close();
    }
  }
  DynamicJsonDocument doc(24576);doc["version"]=1;doc["id"]=id;doc["range"]=range;doc["bucket"]=bucket;doc["time"]=now;doc["utc_offset"]=UTC_OFFSET;
  auto points=doc.createNestedArray("points");
  for(const Bucket& b:bins){if(!b.tn&&!b.hn&&b.battery<0)continue;auto o=points.createNestedObject();o["t"]=b.t;
    if(b.tn){o["temperature"]=nearbyint(b.ts/b.tn*100)/100;o["temperature_min"]=b.tmin;o["temperature_max"]=b.tmax;}
    else{o["temperature"]=nullptr;o["temperature_min"]=nullptr;o["temperature_max"]=nullptr;}
    if(b.hn){o["humidity"]=nearbyint(b.hs/b.hn*100)/100;o["humidity_min"]=b.hmin;o["humidity_max"]=b.hmax;}
    else{o["humidity"]=nullptr;o["humidity_min"]=nullptr;o["humidity_max"]=nullptr;}
    if(b.battery>=0)o["battery"]=b.battery;else o["battery"]=nullptr;
  }sendJSON(200,doc);
}
void postLabels(){
  String body=http.arg("plain");if(!body.length()||body.length()>1024){errorJSON(400,"body must be 1 to 1024 bytes");return;}
  DynamicJsonDocument doc(2048);auto err=deserializeJson(doc,body);
  if(err||!doc["id"].is<const char*>()||(!doc["name"].isNull()&&!doc["name"].is<const char*>())||
      (!doc["room"].isNull()&&!doc["room"].is<const char*>())){errorJSON(400,"expected {id, name, room}");return;}
  int i=findSensor(normalize(doc["id"].as<String>()));if(i<0){errorJSON(404,"unknown thermometer");return;}
  String oldLabel=sensors[i].label,oldRoom=sensors[i].room;
  sensors[i].label=labelText(doc["name"]|"");sensors[i].room=labelText(doc["room"]|"");
  if(!saveState()){sensors[i].label=oldLabel;sensors[i].room=oldRoom;errorJSON(500,"state write failed");return;}
  StaticJsonDocument<64> reply;reply["ok"]=true;sendJSON(200,reply);
}
// Raw, idempotent, timestamp-cursor export for permanent phone storage.
// No acknowledgement deletes data: each phone can independently catch up within 30 days.
void getSamples(){
  String id=normalize(http.arg("id"));int idx=findSensor(id);
  if(idx<0){errorJSON(404,"unknown thermometer");return;}
  String afterText=http.arg("after");
  for(unsigned i=0;i<afterText.length();++i)if(afterText[i]<'0'||afterText[i]>'9'){errorJSON(400,"invalid after");return;}
  int64_t after=strtoll(afterText.c_str(),nullptr,10),now=nowSeconds();
  if(after<0||after>4102444800LL){errorJSON(400,"invalid after");return;}
  if(!now||!fsOK){errorJSON(503,"time or storage unavailable");return;}
  int limit=http.hasArg("limit")?http.arg("limit").toInt():96;limit=std::max(1,std::min(96,limit));
  DynamicJsonDocument doc(24576);doc["version"]=1;doc["id"]=id;doc["source"]=sourceId;
  doc["time"]=now;doc["utc_offset"]=UTC_OFFSET;doc["retention_start"]=now-30*86400;
  doc["gap"]=after>0&&after<now-30*86400;auto out=doc.createNestedArray("samples");
  int64_t next=after,start=std::max(after,now-30*86400);bool more=false;
  for(int64_t day=(start+UTC_OFFSET)/86400;day<=(now+UTC_OFFSET)/86400&&!more;++day){
    File f=LittleFS.open(dayFile(day),"r");if(!f)continue;Frame h;Sample rows[MAX_SENSORS];uint16_t seen[288]={};
    while(readFrame(f,h,rows)){
      int64_t t=day*86400-UTC_OFFSET+h.slot*300;
      if(t>after&&t>=now-30*86400)for(unsigned i=0;i<h.count;++i){auto& s=rows[i];
        if(s.sensor!=idx||(seen[s.slot]&(1u<<idx)))continue;seen[s.slot]|=1u<<idx;
        if(out.size()>=unsigned(limit)){more=true;break;}
        JsonObject o=out.createNestedObject();o["t"]=t;
        if(s.temperature==INT16_MIN)o["temperature"]=nullptr;else o["temperature"]=s.temperature/100.0;
        if(s.humidity==UINT16_MAX)o["humidity"]=nullptr;else o["humidity"]=s.humidity/100.0;
        if(s.battery==255)o["battery"]=nullptr;else o["battery"]=s.battery;
        next=t;
      }if(more)break;delay(0);
    }f.close();
  }
  doc["next_after"]=next;doc["has_more"]=more;sendJSON(200,doc);
}
void startHTTP(){
  http.on("/health",HTTP_GET,[]{http.send(200,"application/json","{\"ok\":true}");});
  http.on("/sensors",HTTP_GET,getSensors);http.on("/history",HTTP_GET,getHistory);http.on("/labels",HTTP_POST,postLabels);
  http.on("/samples",HTTP_GET,getSamples);
  http.onNotFound([]{errorJSON(http.method()==HTTP_GET?404:405,http.method()==HTTP_GET?"not found":"method not allowed");});
  http.begin();httpStarted=true;
}
void drawLine(unsigned slot,int y,const String& text,uint16_t color,const lgfx::IFont* font=&fonts::Font2){
  if(uiText[slot]==text&&uiColor[slot]==color)return;
  uiText[slot]=text;uiColor[slot]=color;
  if(uiLineReady){
    uiLine.fillSprite(0x0841);uiLine.setFont(font);uiLine.setTextSize(1);
    uiLine.setTextColor(color,0x0841);uiLine.setCursor(6,0);uiLine.print(text);
    uiLine.pushSprite(0,y);
  }else{
    // Allocation failure fallback still avoids clearing the entire display.
    lcd.setFont(font);lcd.setTextSize(1);lcd.setTextColor(color,0x0841);
    lcd.setTextPadding(314);lcd.drawString(text,6,y);lcd.setTextPadding(0);
  }
}
void drawUI(){
  if(sensorCount)page%=(sensorCount+2)/3;
  int layout=(portal?100:0)+sensorCount*10+page;
  if(layout!=uiLayout){
    lcd.fillScreen(0x0841);uiLayout=layout;
    for(auto& text:uiText)text="\x01";
  }
  drawLine(0,4,"Thermo Gateway   "+String(sensorCount)+" / "+String(MAX_SENSORS),TFT_WHITE);
  bool online=WiFi.status()==WL_CONNECTED;
  drawLine(1,24,online?WiFi.localIP().toString()+":18787":portal?"Wi-Fi setup (2.4 GHz)":"Wi-Fi reconnecting...",online?TFT_GREEN:TFT_ORANGE);
  if(portal){
    drawLine(2,52,apName,TFT_ORANGE);drawLine(3,74,"Password: "+apPassword,TFT_ORANGE);
    drawLine(4,96,"Open "+WiFi.softAPIP().toString(),TFT_WHITE);drawLine(5,120,"Connect to your home Wi-Fi",TFT_WHITE);
  }else if(!sensorCount){drawLine(2,74,"Listening for thermometers...",TFT_WHITE);}
  else for(unsigned row=0;row<3;++row){
    unsigned i=page*3+row;if(i>=sensorCount)break;const Sensor& s=sensors[i];int y=51+row*52;
    drawLine(2+row*2,y,displayName(s).substring(0,60),TFT_WHITE,&fonts::efontTW_16);
    String reading=(s.reading.fields&TEMP?String(s.reading.temperature,2):"--")+" C  ";
    reading+=(s.reading.fields&HUM?String(s.reading.humidity,2):"--")+" %  ";
    reading+=(s.reading.fields&BATT?String(s.reading.battery):"--")+"%  ";
    int64_t now=nowSeconds(),age=s.updated&&now?now-s.updated:-1;
    reading+=age<0?"waiting":age<60?String((long)age)+"s":String((long)(age/60))+"m";
    drawLine(3+row*2,y+20,reading,age>=0&&age<=300?TFT_WHITE:TFT_ORANGE);
  }
  drawLine(8,211,!fsOK?"Storage error - USB: FORMAT":!nowSeconds()?"Waiting for NTP time...":"Tap: next page   BLE "+String(packetCount),TFT_LIGHTGREY);
}
void startPortal(){
  if(portal)return;portal=true;
  wifiManager.setConfigPortalBlocking(false);wifiManager.setConfigPortalTimeout(300);
  wifiManager.startConfigPortal(apName.c_str(),apPassword.c_str());
}
void setup(){
  Serial.begin(115200);delay(300);bootId=esp_random();
  Serial.printf("BOOT id=%08x reason=%d gateway=1.4\n",bootId,esp_reset_reason());
  preferences.begin("thermo",false);inverted=preferences.getBool("invert",false);
  sourceId=preferences.getString("source","");
  if(!sourceId.length()){sourceId=String(uint32_t(ESP.getEfuseMac()>>24),HEX)+"-"+String(esp_random(),HEX);preferences.putString("source",sourceId);}
  lcd.init();lcd.setRotation(PANEL_ST7789?1:3);lcd.invertDisplay(inverted);lcd.setBrightness(160);
  displayActiveUs=esp_timer_get_time();
  uiLine.setColorDepth(16);uiLine.setPsram(false);uiLineReady=uiLine.createSprite(320,20)!=nullptr;
  Serial.printf("DISPLAY line buffer=%d bytes=12800; changed lines only\n",uiLineReady);
  Serial.println("MODE GATEWAY (automatic)");
  // Never silently format an unknown/old filesystem. Initial format is an explicit USB command.
  fsOK=LittleFS.begin(false);if(fsOK)loadState();else Serial.println("STORAGE not mounted; type FORMAT to initialize gateway storage");
  apName="Thermo-Setup-"+String(uint32_t(ESP.getEfuseMac()>>24),HEX);
  apPassword=String(esp_random(),HEX)+String(esp_random()&0xffff,HEX);
  wifiManager.setDebugOutput(false);wifiManager.setConnectTimeout(15);wifiManager.setSaveConfigCallback([]{Serial.println("WIFI settings saved");});
  WiFi.onEvent([](WiFiEvent_t event,WiFiEventInfo_t info){
    if(event==ARDUINO_EVENT_WIFI_STA_DISCONNECTED)Serial.printf("WIFI disconnected reason=%u\n",info.wifi_sta_disconnected.reason);
  });
  WiFi.setHostname("thermo-cyd");bool wifiModeOK=WiFi.mode(WIFI_STA);WiFi.setAutoReconnect(true);wifiStartedUs=esp_timer_get_time();lastWiFiAttempt=wifiStartedUs;
  IPAddress fixedIP,fixedGateway,fixedMask,fixedDNS;
  if(fixedIP.fromString(preferences.getString("ip",""))&&fixedGateway.fromString(preferences.getString("gw",""))&&
     fixedMask.fromString(preferences.getString("mask",""))&&fixedDNS.fromString(preferences.getString("dns",""))){
    bool configured=WiFi.config(fixedIP,fixedGateway,fixedMask,fixedDNS);
    Serial.printf("WIFI static=%s configured=%d\n",fixedIP.toString().c_str(),configured);
  }
  int wifiBeginStatus=WiFi.begin();Serial.printf("WIFI init mode=%d begin=%d\n",wifiModeOK,wifiBeginStatus);
  configTime(UTC_OFFSET,0,"time.google.com","pool.ntp.org","time.cloudflare.com");
  packets=xQueueCreate(32,sizeof(Packet));
  if(!packets){Serial.println("FATAL queue allocation");return;}
  bool bleOK=NimBLEDevice::init("");scanner=NimBLEDevice::getScan();
  // IDF 5 supports PS_NONE during coexistence; IDF 4.4 aborts (#9595).
  WiFi.setSleep(false);
  scanner->setScanCallbacks(&callbacks,true);scanner->setActiveScan(false);
  scanner->setInterval(160);scanner->setWindow(40);scanner->setMaxResults(0);
  Serial.println("RADIO passive BLE window=40ms interval=160ms duty=25%; WiFi sleep disabled");
  bool scanOK=scanner->start(0,false,true);Serial.printf("BLE init=%d scan=%d\n",bleOK,scanOK);
  drawUI();
  Serial.println("COMMANDS: STATUS, REBOOT, WIFI (setup), INVERT (display), FORMAT (initialize storage)");
}
String serialLine;
void usbCommands(){
  while(Serial.available()){char c=Serial.read();if(c=='\r')continue;
    if(c!='\n'){if(serialLine.length()<64)serialLine+=c;else serialLine="";continue;}
    serialLine.trim();
    if(serialLine=="REBOOT"){saveState();Serial.println("REBOOT requested");Serial.flush();ESP.restart();}
    else if(serialLine.startsWith("STATIC ")){
      char ipText[16],gwText[16],maskText[16],dnsText[16],extra[2];IPAddress ip,gw,mask,dns;
      int count=sscanf(serialLine.c_str(),"STATIC %15s %15s %15s %15s %1s",ipText,gwText,maskText,dnsText,extra);
      if(count==4&&ip.fromString(ipText)&&gw.fromString(gwText)&&mask.fromString(maskText)&&dns.fromString(dnsText)&&
         uint32_t(ip)&&uint32_t(gw)&&uint32_t(mask)&&uint32_t(dns)&&((uint32_t(ip)&uint32_t(mask))==(uint32_t(gw)&uint32_t(mask)))){
        preferences.putString("ip",ipText);preferences.putString("gw",gwText);preferences.putString("mask",maskText);preferences.putString("dns",dnsText);
        Serial.println("STATIC saved; reboot to apply");
      }else Serial.println("STATIC invalid; expected IP gateway mask DNS");
    }
    else if(serialLine=="WIFI")startPortal();
    else if(serialLine=="INVERT"){inverted=!inverted;preferences.putBool("invert",inverted);lcd.invertDisplay(inverted);drawUI();}
    else if(serialLine=="FORMAT"&&!fsOK){fsOK=LittleFS.format()&&LittleFS.begin(false);Serial.printf("FORMAT ok=%d\n",fsOK);}
    else if(serialLine=="STATUS")Serial.printf("STATUS ip=%s uptime=%llu heap=%u fs=%d sensors=%u packets=%u\n",WiFi.localIP().toString().c_str(),esp_timer_get_time()/1000000,ESP.getFreeHeap(),fsOK,sensorCount,packetCount);
    serialLine="";
  }
}
void loop(){
  uint64_t us=esp_timer_get_time();usbCommands();if(packets)drainPackets();
  if(portal){wifiManager.process();if(!wifiManager.getConfigPortalActive())portal=false;}
  static bool connected=false,offeredPortal=false;static uint64_t lastNtpAttempt=0;
  if(WiFi.status()==WL_CONNECTED){if(!connected){connected=true;WiFi.setSleep(false);
    configTime(UTC_OFFSET,0,"time.google.com","pool.ntp.org","time.cloudflare.com");lastNtpAttempt=us;
    Serial.printf("IP http://%s:18787 sleep=%d\n",WiFi.localIP().toString().c_str(),WiFi.getSleep());if(!httpStarted)startHTTP();}
    if(!nowSeconds()&&us-lastNtpAttempt>30000000){
      configTime(UTC_OFFSET,0,"time.google.com","pool.ntp.org","time.cloudflare.com");lastNtpAttempt=us;Serial.println("NTP retry");}}
  else {connected=false;if(us-wifiStartedUs>45000000&&!httpStarted&&!portal&&!offeredPortal){startPortal();lastWiFiAttempt=us;offeredPortal=true;}
    if(!portal&&us-lastWiFiAttempt>30000000){WiFi.reconnect();lastWiFiAttempt=us;}}
  if(httpStarted)http.handleClient();
  int64_t now=nowSeconds();if(now){for(unsigned i=0;i<sensorCount;++i)if(sensors[i].heard&&!sensors[i].updated)sensors[i].updated=now-(us-sensors[i].heardUs)/1000000;}
  if(now&&now%300>=1)recordHistory();
  if(dirty&&us-lastStateSave>5000000)saveState();
  const uint64_t displayNow=esp_timer_get_time();uint16_t x,y;
  bool touched=lcd.getTouch(&x,&y);
  if(touched&&!touchHeld&&displayNow-lastTouch>250000){
    lastTouch=displayNow;
    if(!displayAwake){
      // Wake tap is consumed; paint fresh values before lighting the panel.
      uiLayout=-1;drawUI();lcd.setBrightness(160);displayAwake=true;
      displayActiveUs=esp_timer_get_time();lastUI=displayActiveUs;
      Serial.println("DISPLAY awake; timeout=10s");
    }else{++page;displayActiveUs=displayNow;lastUI=0;}
  }
  touchHeld=touched;
  if(displayAwake&&displayNow>=displayActiveUs&&displayNow-displayActiveUs>=DISPLAY_TIMEOUT_US){
    lcd.setBrightness(0);displayAwake=false;Serial.println("DISPLAY off; gateway stays active");
  }
  if(displayAwake&&displayNow>=lastUI&&displayNow-lastUI>2000000){drawUI();lastUI=displayNow;}
  if(us-lastLog>10000000){Serial.printf("LIVE boot=%08x uptime=%llu heap=%u minheap=%u packets=%u drops=%u sensors=%u limit_drops=%u ntp=%lld wifi=%d\n",bootId,us/1000000,ESP.getFreeHeap(),ESP.getMinFreeHeap(),packetCount,queueDrops,sensorCount,unknownDropped,now,WiFi.status());lastLog=us;}
  delay(2);
}
