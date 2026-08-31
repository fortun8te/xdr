# XDR

Mac menu-bar brightness for HDR and Pro Display XDR. Goes brighter than the system slider. Drag it, the screen follows, color gamut stays put.

## What It Does

XDR gives you real-time brightness control for high-dynamic-range displays. Click the menu bar icon, adjust the slider, and your display brightness changes immediately while keeping the color gamut intact. No fiddling through system settings. No overshooting.

Real example: You're editing photos in Final Cut Pro on a ProDisplay XDR in a bright room. Your edit suite is getting washed out. You tap the menu bar, bump the brightness up 20%, colors stay perfect, you're back to work in two seconds.

## Why This Matters

macOS gives you global brightness control, but HDR displays need something smarter. They use display gamma tables to adjust intensity while preserving the wide color gamut that makes them worth owning. XDR handles this directly, so you get precise control without losing the color accuracy that HDR is for.

The slider is live. No confirmation dialogs. No lag. Adjust and see.

## How It Works

- **SwiftUI menu bar** for the UI
- **macOS display gamma tables** for the actual brightness adjustment
- **Real-time response** as you drag
- **Persistent settings** that survive a restart

## Get Started

Launch it, click the menu bar icon, adjust the slider. Your brightness setting is saved automatically.
