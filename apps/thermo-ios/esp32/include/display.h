#pragma once
#include <LovyanGFX.hpp>
class Display : public lgfx::LGFX_Device {
  lgfx::Bus_SPI bus;
#if PANEL_ST7789
  lgfx::Panel_ST7789 panel;
#else
  lgfx::Panel_ILI9341 panel;
#endif
  lgfx::Light_PWM light;
  lgfx::Touch_XPT2046 touch;
public:
  Display() {
    auto b=bus.config(); b.spi_host=HSPI_HOST; b.spi_mode=0;
    b.freq_write=40000000; b.freq_read=16000000;
    b.pin_sclk=14; b.pin_mosi=13; b.pin_miso=12; b.pin_dc=2;
    b.dma_channel=1; bus.config(b); panel.setBus(&bus);
    auto p=panel.config(); p.pin_cs=15; p.pin_rst=12; p.pin_busy=-1;
    p.panel_width=240; p.panel_height=320; p.memory_width=240; p.memory_height=320;
    p.offset_x=0; p.offset_y=0; p.readable=true;
    p.invert=false; p.rgb_order=false; p.bus_shared=false;
    panel.config(p);
    auto l=light.config(); l.pin_bl=21; l.invert=false; l.freq=44100; l.pwm_channel=7;
    light.config(l); panel.setLight(&light);
    auto t=touch.config(); t.spi_host=VSPI_HOST; t.freq=1000000;
    t.pin_sclk=25; t.pin_mosi=32; t.pin_miso=39; t.pin_cs=33; t.pin_int=-1;
    t.x_min=300; t.x_max=3900; t.y_min=200; t.y_max=3700;
    t.offset_rotation=PANEL_ST7789?4:6; t.bus_shared=false;
    touch.config(t); panel.setTouch(&touch); setPanel(&panel);
  }
};
