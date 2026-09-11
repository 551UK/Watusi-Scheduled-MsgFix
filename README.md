# Watusi Scheduled Message Fix

A small rootless companion tweak for **Watusi 3** that targets scheduled messages failing to send when WhatsApp is closed or the device is locked.

## What it fixes

Watusi already wakes WhatsApp for scheduled messages through `callservicesd` using its VoIP push path. On the affected iOS 16 setup, iOS can still report WhatsApp as prevented from being launched, so the scheduled trigger works while WhatsApp is alive but fails when iOS needs to launch it.

This tweak hooks that launch-prevention check and returns **not prevented only for WhatsApp / WhatsApp Business**. Other apps keep the normal iOS behaviour.

## Tested target

- iOS 16.2
- Dopamine rootless
- WhatsApp 26.32.75
- Watusi 3 1.3.23
- WatusiTools 2.8.4

## Install / use

Install the package and it works automatically. There is no settings page or toggle in this first test build because the fix is deliberately limited to Watusi's WhatsApp wake path.

## Build

The GitHub Actions workflow builds a rootless `iphoneos-arm64` package with Theos. The tweak injects only into `callservicesd` / `com.apple.calls.telephonyutilities`.

## Status

`1.0.0` is the first targeted build for testing the closed/locked scheduled-message path.
