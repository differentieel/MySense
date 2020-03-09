# Copyright 2018, Teus Hagen, ver. Behoud de Parel, GPLV3
# $Id: main.py,v 1.21 2020/03/09 10:46:54 teus Exp teus $

def setWiFi():
  try:
    W_SSID =  'MySense-AAAA'
    try: from Config import W_SSID
    except: pass
    if W_SSID[-4:] == 'AAAA':
        from machine import unique_id
        import binascii
        W_SSID = W_SSID[:-4]+binascii.hexlify(unique_id()).decode('utf-8')[-4:].lower()
    PASS = 'www.pycom.io' # only for 1 hr, then powered off (dflt) or changed
    from network import WLAN
    wlan = WLAN()
    wlan.init(mode=WLAN.AP,ssid=W_SSID, auth=(WLAN.WPA2,PASS), channel=7, antenna=WLAN.INT_ANT)
  except: pass

def runMySense():
  import MySense
  MySense.runMe()  # should never return
  import myReset   # cold reboot or sleep forever
  myReset.myEnd()

setWiFi() # will be switched off after 60 min

from machine import wake_reason, PWRON_WAKE, RTC_WAKE
if wake_reason()[0] == RTC_WAKE:  # wokeup from deepsleep
  from machine import ADC, Pin
  accuPin = 'P17'
  try: from Config import accuPin
  except: pass
  volt = (ADC(0).channel(pin=accuPin, attn=ADC.ATTN_11DB).value())*0.004271845
  if 1.0 < volt < 10.0: # wait for sun
    from machine import deepsleep
    deepsleep(60*60*1000) # one hour
if wake_reason()[0] != PWRON_WAKE:
  runMySense()
else: # work around fake wakeup
  try:
    from pycom import nvs_get
    from time import ticks_ms
    if nvs_get('AlarmSlp')*1000 < ticks_ms():
      runMySense() # reboot from deepsleep
  except: pass

# arrived from power cycle
from machine import Pin
# change next to False in operational modus
REPL = False
try:
  from Config import REPL
except: pass
try:
  from Config import replPin # if not in config act in old style
  if not Pin(replPin,mode=Pin.IN).value():
    REPL = True
    print("REPL enforced, pin %s" % str(REPL))
  else: REPL = False
except: pass

if not REPL:
  runMySense()

# go into REPL mode
print("No auto MySense start\nTo start MySense loop (reset config, cleanup nvs):")
print("  import MySense; MySense.runMe(debug=False,reset=True)")
try:
  from pycom import heartbeat, rgbled
  from time import sleep
  heartbeat(False)
  for x in range(3):
    rgbled(0xf96015); sleep(0.1)
    rgbled(0x0); sleep(0.1)
    rgbled(0x0000ff); sleep(0.1)
    rgbled(0x0); sleep(0.4)
  heartbeat(True)
except: pass
