CC      = clang
ARCH   ?= arm64e
CFLAGS  = -arch $(ARCH) -dynamiclib -fobjc-arc -framework Cocoa

SRC_APP    = /System/Applications/Utilities/Terminal.app
APP        = $(HOME)/Applications/Terminl.app
DYLIB      = $(APP)/Contents/Frameworks/terminl.dylib
PLIST      = $(APP)/Contents/Info.plist
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all build install uninstall clean

all: build

build: terminl.dylib

terminl.dylib: terminl.m
	$(CC) $(CFLAGS) -o $@ $<

# Copy the system Terminal to ~/Applications, embed the dylib, inject it via LSEnvironment, ad-hoc re-sign.
install: terminl.dylib
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(APP)"
	cp -R "$(SRC_APP)" "$(APP)"
	mkdir -p "$(APP)/Contents/Frameworks"
	cp terminl.dylib "$(DYLIB)"
	/usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' \
		-c 'Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $(DYLIB)' "$(PLIST)"
	/usr/libexec/PlistBuddy -c "Add :TerminlSourceVersion string $$(defaults read $(SRC_APP)/Contents/Info CFBundleVersion)" "$(PLIST)"
	codesign -fs - "$(DYLIB)"
	codesign -fs - "$(APP)"
	"$(LSREGISTER)" -f "$(APP)"
	@echo "installed $(APP) — re-run after macOS updates Terminal"

uninstall:
	-[ -d "$(APP)" ] && "$(LSREGISTER)" -u "$(APP)"
	rm -rf "$(APP)"
	@echo "removed $(APP)"

clean:
	rm -f terminl.dylib
