AudioStreamer fork by yarshure
======
example private musci format decode

code use in mac app store
https://itunes.apple.com/cn/app/fei-le-dian-tai/id491643056?mt=12
iOS App Store
https://itunes.apple.com/us/app/fei-le-yin-le-jing-xuan/id492607981?mt=8
this app online music Library have  offline, so I open my work on decode private music format file.

yarhusre
2012.12.07 Shanghai 

A fork of DigitalDJ's AudioStreamer (which is a fork jfricker's AudioStreamer (which is a fork of the original AudioStreamer by mattgallagher))


Forked and cherry-picked to get a number of community addons and fixes:
- Shoutcast metadata [jfricker]
- MIME type detection [andybee]
- HE-AACv2 [idevsoftware]
- Level Metering [idevsoftware]
- NSThread memory leak [mattgallagher]
- Fix alert spam / Invisible alerts by dispatching alerts on the main (GUI) thread instead of the notification thread [sebsto]
- Fix compilation issues in Mac OS X Sample App [sebsto]
- Fix compilation issue when SHOUTCAST_METADAT flag is defined [sebsto]
- Fix iPhone apps crashes in SHOUTCAST_METADATA mode when returning from Background [sebsto]
- Album metadata [nickpack]
- Buffer fill percentage [rayh]
- Possible fix for playing non-VBR WAV streams [isalkind]
- Invalid byte range header fix [whyz]
- Compatibility with OS3.x [bradfordcp]

Fixes and features I've implemented:
- Fixed interruption crashes
- Background buffering
- Play/pause from iPod controls
- Stop all UI updating and timers while backgrounded
- Retina display example
- Support for Pause button in UI
- Local Notifications (outside app) on error




