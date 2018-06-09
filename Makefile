include $(THEOS)/makefiles/common.mk

TWEAK_NAME = StreakNotify
StreakNotify_FILES = Tweak.xm 
StreakNotify_PRIVATE_FRAMEWORKS = AppSupport
StreakNotify_LIBRARIES = rocketbootstrap
StreakNotify_CFLAGS = -fobjc-arc -DTHEOS

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += streaknotify
SUBPROJECTS += streaknotifyd
SUBPROJECTS += friendmojilist
include $(THEOS_MAKE_PATH)/aggregate.mk

before-stage:: 
	find . -name ".DS_Store" -delete

after-install::
	install.exec "killall -9 backboardd"


