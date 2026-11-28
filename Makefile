APP  := build/rayfast.app
BIN  := $(APP)/Contents/MacOS/rayfast
OPT  := -fobjc-arc -Os -Wall -Wno-deprecated-declarations -mmacosx-version-min=13.0
SRC  := $(wildcard *.m)
LIBS := -framework Cocoa -framework Carbon -framework QuartzCore -framework IOSurface

all: $(BIN)

$(BIN): $(SRC) rf.h Info.plist
	@mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	clang $(OPT) $(SRC) -o $@ $(LIBS) -Wl,-dead_strip
	strip -x $@
	codesign -s - -f $(APP) 2>/dev/null || true

run: all
	-pkill -x rayfast; open $(APP)

# copies to ~/Applications and starts it at login via a LaunchAgent
install: all
	-pkill -x rayfast
	rm -rf ~/Applications/rayfast.app && mkdir -p ~/Applications && cp -R $(APP) ~/Applications/
	sed "s#HOME#$$HOME#" local.rayfast.plist > ~/Library/LaunchAgents/local.rayfast.plist
	-launchctl bootout gui/$$(id -u)/local.rayfast 2>/dev/null
	launchctl bootstrap gui/$$(id -u) ~/Library/LaunchAgents/local.rayfast.plist

uninstall:
	-launchctl bootout gui/$$(id -u)/local.rayfast
	rm -f ~/Library/LaunchAgents/local.rayfast.plist
	rm -rf ~/Applications/rayfast.app

# a separately named copy for experiments, so tests never touch the real running instance
# (make test-app TESTNAME=rayfast-test-foo gives parallel test runs their own process name)
TESTNAME ?= rayfast-test
TEST := build/$(TESTNAME).app
test-app: all
	rm -rf $(TEST) && cp -R $(APP) $(TEST)
	mv $(TEST)/Contents/MacOS/rayfast $(TEST)/Contents/MacOS/$(TESTNAME)
	plutil -replace CFBundleExecutable -string $(TESTNAME) $(TEST)/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string local.$(subst -,.,$(TESTNAME)) $(TEST)/Contents/Info.plist
	plutil -replace CFBundleName -string $(TESTNAME) $(TEST)/Contents/Info.plist
	codesign -s - -f $(TEST) 2>/dev/null || true

clean:
	rm -rf build
.PHONY: all run install uninstall test-app clean
