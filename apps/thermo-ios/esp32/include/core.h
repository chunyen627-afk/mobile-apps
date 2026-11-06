#pragma once
#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include <algorithm>

namespace thermo {
enum Field : uint8_t { TEMP=1, HUM=2, BATT=4, VOLT=8 };
struct Reading {
  uint8_t fields=0;
  double temperature=0, humidity=0, voltage=0;
  int battery=0;
  const char* format=nullptr;
};
inline uint16_t u16(const uint8_t* p) { return p[0] | (uint16_t(p[1])<<8); }
inline int objectSize(uint8_t id) {
  static const uint8_t sizes[] = {
    1,1,2,2,3,3,2,2,2,1,3,3,2,2,2,1,1,1,2,2,2,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1
  };
  if(id<sizeof(sizes)) return sizes[id];
  switch(id) {
    case 0x3A: case 0x46: case 0x5A: case 0x5B: case 0x5C: case 0x5D:
    case 0x5E: case 0x60: return 1;
    case 0x3C: case 0x3D: case 0x3F: case 0x40: case 0x41: case 0x43:
    case 0x44: case 0x45: case 0x47: case 0x48: case 0x49: case 0x4A:
    case 0x51: case 0x52: return 2;
    case 0x42: case 0x4B: return 3;
    case 0x3E: case 0x4C: case 0x4D: case 0x4E: case 0x4F: case 0x50: return 4;
    default: return 0;
  }
}
inline Reading decode(uint16_t uuid, const uint8_t* p, size_t n) {
  Reading r;
  if(uuid==0xFCD2) {
    if(n<2 || (p[0]&1) || (p[0]>>5)!=2) return r;
    r.format="bthome";
    for(size_t i=1;i<n;) {
      uint8_t id=p[i++]; int len=objectSize(id);
      if(!len || i+len>n) break; // Exactly like the Python reference: retain earlier fields.
      switch(id) {
        case 1: r.battery=p[i]; r.fields|=BATT; break;
        case 2: r.temperature=int16_t(u16(p+i))/100.0; r.fields|=TEMP; break;
        case 0x45: r.temperature=int16_t(u16(p+i))/10.0; r.fields|=TEMP; break;
        case 3: r.humidity=u16(p+i)/100.0; r.fields|=HUM; break;
        case 0x2E: r.humidity=p[i]; r.fields|=HUM; break;
        case 0x0C: r.voltage=u16(p+i)/1000.0; r.fields|=VOLT; break;
      }
      i+=len;
    }
  } else if(uuid==0x181A && n==15) {
    r.format="pvvx"; r.fields=15;
    r.temperature=int16_t(u16(p+6))/100.0;
    r.humidity=u16(p+8)/100.0; r.voltage=u16(p+10)/1000.0; r.battery=p[12];
  } else if(uuid==0x181A && n==13) {
    r.format="atc1441"; r.fields=15;
    r.temperature=int16_t((uint16_t(p[6])<<8)|p[7])/10.0;
    r.humidity=p[8]; r.battery=p[9]; r.voltage=((uint16_t(p[10])<<8)|p[11])/1000.0;
  }
  return r;
}
inline int batteryFromVoltage(double mv) {
  // Python round uses ties-to-even.
  return std::max(0,std::min(100,int(nearbyint((mv-2200)/9))));
}
inline void merge(Reading& dst, const Reading& src) {
  if(src.fields&TEMP) dst.temperature=src.temperature;
  if(src.fields&HUM) dst.humidity=src.humidity;
  if(src.fields&BATT) dst.battery=src.battery;
  if(src.fields&VOLT) dst.voltage=src.voltage;
  if(!(src.fields&BATT) && !(dst.fields&BATT) && (src.fields&VOLT) && src.voltage) {
    dst.battery=batteryFromVoltage(src.voltage*1000); dst.fields|=BATT;
  }
  dst.fields|=src.fields; dst.format=src.format;
}
constexpr int UTC_OFFSET=28800;
inline int64_t bucketTime(int64_t t,int seconds) { return (t+UTC_OFFSET)/seconds*seconds-UTC_OFFSET; }
inline int64_t historyStart(int64_t now,int days) {
  return days==1 ? now-86400 : bucketTime(now,86400)-(days-1)*86400;
}
struct Bucket {
  int64_t t=0;
  double ts=0, hs=0, tmin=0,tmax=0,hmin=0,hmax=0;
  unsigned tn=0,hn=0;
  int battery=-1;
  void add(const Reading& r) {
    if(r.fields&TEMP) { ts+=r.temperature; if(!tn) tmin=tmax=r.temperature;
      else {tmin=std::min(tmin,r.temperature);tmax=std::max(tmax,r.temperature);} ++tn; }
    if(r.fields&HUM) { hs+=r.humidity; if(!hn) hmin=hmax=r.humidity;
      else {hmin=std::min(hmin,r.humidity);hmax=std::max(hmax,r.humidity);} ++hn; }
    if(r.fields&BATT) battery=battery<0?r.battery:std::min(battery,r.battery);
  }
};
// One daily file for all sensors: 4 sensors + 8-byte frame header: 40 * 288 * 31 = 357,120 bytes.
// Null sentinels preserve partial readings. slots are local-day five-minute indices.
struct __attribute__((packed)) Sample {
  uint16_t slot;
  int16_t temperature;
  uint16_t humidity;
  uint8_t battery;
  uint8_t sensor;
};
static_assert(sizeof(Sample)==8,"history storage contract");
}
