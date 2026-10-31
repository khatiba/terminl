# Terminl

Dear Apple, since Tahoe, Terminal.app is near perfect, there are just a couple annoyances that would make it just right. The code to fix them is tiny and the terminal interface is quickly becoming the new web browser of our age and Terminal.app has the potential to dominate.

## Stock

<p>
  <img src="https://akhatib.s3.us-west-2.amazonaws.com/assets/stock-window-sizing.gif" alt="Patched Terminal" width="49%">
  <img src="https://akhatib.s3.us-west-2.amazonaws.com/assets/stock-terminal.png" alt="Stock Terminal" width="49%">
</p>


## Patched

<img src="https://akhatib.s3.us-west-2.amazonaws.com/assets/patched-terminal.png" alt="Patched Terminal">

### 1. Chromeless titlebar

The titlebar color is ugly and it's trivial now to make titlebar transparent so the window background shows through seamlessly.

### 2. Tab bar in the titlebar

Vertical space is already scarce so just put the tabs in the titlebar. It's still the real `NSTabBar`, so dragging, reordering, the new-tab button and the context menus keep working. While tabs are showing, the window title and proxy icon are hidden. With only one tab, the regular title comes back.

### 3. Consistent window size

- Normally Terminal resizes the window when the tab bar appears or disappears and it's jarring, especially when the window is maximized.
- Zoom (green button / double-click the titlebar) fills the whole visible screen, not a size rounded down to whole character cells which leaves a gap on the right and bottom.

This small dylib patches Terminal.app but must make a copy, swizzle and re-sign, but other than that, it's stock Terminal.

## Install

```sh
curl -fsSL https://github.com/khatiba/terminl/releases/latest/download/install.sh | sh
```

> [!NOTE]
> Terminl.app keeps the stock bundle identifier (`com.apple.Terminal`), so it shares preferences with Terminal.app. Your profiles, themes, fonts and settings carry over, and any changes you make in one show up in the other.


##### Uninstall

```sh
curl -fsSL https://github.com/khatiba/terminl/releases/latest/download/install.sh | sh -s -- --uninstall
```

## Requirements to Build

- macOS on Apple Silicon
- clang (`xcode-select --install`)

All the code is in `terminl.m`

Note: a macOS update can break this since it uses private AppKit view classes and Terminal internals (`TTView`, `TTWindow`, `TTWindowController`, `NSTabBar`, etc.)


## Usage

```sh
make build      # build terminl.dylib
make install    # build, then create ~/Applications/Terminl.app with the dylib injected
make uninstall  # remove ~/Applications/Terminl.app
make clean      # delete build output
```

`install` copies `/System/Applications/Utilities/Terminal.app`, puts `terminl.dylib` in `Contents/Frameworks`, adds `DYLD_INSERT_LIBRARIES` to the app's `LSEnvironment`, and ad-hoc re-signs the bundle.

Once macOS updates Terminal, run `make install` again so the copy picks up the new version.
