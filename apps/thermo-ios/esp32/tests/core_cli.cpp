#include "core.h"
#include <iostream>
#include <iomanip>
#include <string>
#include <sstream>
#include <vector>
using namespace thermo;
void output(const Reading& r){
  if(!r.fields){std::cout<<"null\n";return;}
  std::cout<<"{\"format\":\""<<r.format<<"\"";
  if(r.fields&TEMP)std::cout<<",\"temperature\":"<<r.temperature;
  if(r.fields&HUM)std::cout<<",\"humidity\":"<<r.humidity;
  if(r.fields&BATT)std::cout<<",\"battery\":"<<r.battery;
  if(r.fields&VOLT)std::cout<<",\"voltage\":"<<r.voltage;
  std::cout<<"}\n";
}
int main(){
  std::cout<<std::setprecision(12);std::string line;
  Reading merged;
  while(std::getline(std::cin,line)){
    std::istringstream in(line);char cmd;in>>cmd;
    if(cmd=='D'||cmd=='M'){unsigned uuid;std::string hex;in>>std::hex>>uuid>>hex;std::vector<uint8_t> bytes;
      for(size_t i=0;i+1<hex.size();i+=2)bytes.push_back(std::stoul(hex.substr(i,2),nullptr,16));
      auto r=decode(uuid,bytes.data(),bytes.size());if(cmd=='M'){merge(merged,r);output(merged);}else output(r);
    }else if(cmd=='B'){double mv;in>>mv;std::cout<<batteryFromVoltage(mv)<<"\n";
    }else if(cmd=='H'){int64_t now;int days,n;in>>now>>days>>n;int bs=days==1?1800:86400;
      int64_t start=historyStart(now,days),first=bucketTime(start,bs);Bucket bins[50];
      for(int i=0;i<n;++i){std::getline(std::cin,line);std::istringstream row(line);int64_t t;double temp,hum;int batt;
        row>>t>>temp>>hum>>batt;if(t<start||t<now-30*86400)continue;int idx=(bucketTime(t,bs)-first)/bs;if(idx<0||idx>=50)continue;
        Reading r;r.fields=TEMP|HUM|BATT;r.temperature=temp;r.humidity=hum;r.battery=batt;bins[idx].add(r);}
      std::cout<<"[";bool comma=false;
      for(int i=0;i<50;++i){auto& b=bins[i];if(!b.tn)continue;if(comma)std::cout<<",";comma=true;
        std::cout<<"{\"t\":"<<first+i*bs<<",\"temperature\":"<<nearbyint(b.ts/b.tn*100)/100<<",\"humidity\":"<<nearbyint(b.hs/b.hn*100)/100
          <<",\"battery\":"<<b.battery<<",\"temperature_min\":"<<b.tmin<<",\"temperature_max\":"<<b.tmax
          <<",\"humidity_min\":"<<b.hmin<<",\"humidity_max\":"<<b.hmax<<"}";
      }std::cout<<"]\n";
    }
  }
}
