# Copyright 2018, Teus Hagen, ver. Behoud de Parel, GPLV3
# $Id: main.py,v 1.18 2020/02/16 15:58:02 teus Exp teus $

def setWiFi():
  try:
    from machine import unique_id
    import binascii
    W_SSID =  'MySense-AAAA'
    try: from Config import W_SSID
    except: pass
    if W_SSID[-4:] == 'AAAA':
        W_SSID = W_SSID[:-4]+binascii.hexlify(unique_id()).decode('utf-8')[-4:].lower()
    PASS = 'www.pycom.io' # to be changed later
    from network import WLAN
    wlan = WLAN()
    wlan.init(mode=WLAN.AP,ssid=W_SSID, auth=(WLAN.WPA2,PASS), channel=7, antenna=WLAN.INT_ANT)
  except: pass

def runMySense():
  import MySense
  MySense.runMe()  # should never return
  import myReset   # cold reboot or sleep forever
  myReset.myEnd()

setWiFi()

from machine import wake_reason, PWRON_WAKE
if wake_reason()[0] != PWRON_WAKE: runMySense()
else: # work around fake wakeup
  try:
    from pycom import nvs_get
    from time import ticks_ms
    if nvs_get('AlarmSlp')*1000 < ticks_ms(): runMySense()
  except: pass

# Use True to force REPL mode. use False: REPL depends on replPin,
#                        (for compatebility reasons) sleeppin and accu voltage
REPL = True   # change this to False in operational modus
try:
  from Config import replPin # if not in config act in old style
  from machine import Pin
  if Pin(replPin,mode=Pin.IN).value(): REPL = False
except: pass
if REPL:
  print("No auto MySense start\nTo start MySense loop (reset config, cleanup nvs):")
  print("import MySense\nMySense.runMe(reset=True)")
else: # deepsleep pin set and no accu voltage: go into REPL mode (subject to change)
  try:
    from machine import Pin
    sleepPin = 'P18'
    try: from Config import sleepPin
    except: pass
    # WARNING: PyCom expansion board will show deepsleep pin enabled!
    if Pin(sleepPin,mode=Pin.IN).value(): # deepsleep disabled
      runMySense()
    else: # deepsleep enabled, check for PyCom expansion board looks like accu!
      accuPin = 'P17'
      try: from Config import accuPin
      except: pass
      from machine import ADC
      # WARNING: on PyCom expansion board sleeppin is low and accupin is high!
      if (ADC(0).channel(pin=accuPin, attn=ADC.ATTN_11DB).value())*0.004271845 > 4.8:
        runMySense()
      else:
        from machine import wake_reason, RTC_WAKE, deepsleep
        if wake_reason()[0] == RTC_WAKE:  # wokeup from deepsleep, too low power
          # runMySense()
          deepsleep(60*60*1000)
  except: pass
# go into REPL mode
