# Screen2Story

**Turn screenshots and voice notes into structured visual documentation.**

Screen2Story (S2S) is a lightweight macOS and Windows tool for capturing a workflow while you work.

Start a session, take screenshots with the floating capture bar and add voice notes. Screen2Story stores everything as a structured local project that can be used for documentation, bug reports, tutorials or AI-assisted workflows.

## Features

- 📸 Capture screenshots while you work
- 🎙️ Add voice notes using on-device speech recognition
- 🗂️ Automatically organize screenshots and notes
- 🖼️ Generate visual storyboard exports
- 💻 Local-first: your project data stays on your computer
- 🚫 No account required
- 🚫 No analytics or tracking
- 🚫 No uploads to Screen2Story or ToCrA Studios servers

## Privacy

Screen2Story is designed as a local-first application.

Screenshots, recognized text, projects and exports are processed and stored locally on your computer.

Voice recognition uses the local speech-recognition facilities provided by macOS or Windows. Screen2Story does not upload recordings to ToCrA Studios.

Screen2Story does not transmit your screenshots, notes or project content to ToCrA Studios.

## Requirements

- macOS 14 or newer, or Windows 10/11
- Screen Recording permission on macOS
- Microphone and local Speech Recognition support for voice notes

## Download

https://github.com/ToCrA-Studios/Screen2Story/releases/tag/V1.0.0  

The latest version of Screen2Story is available under **Releases** on this repository.

> Note: The current macOS release is not notarized by Apple. macOS may therefore display a security warning when opening the application for the first time.

## Source Code

The source code for the shared Flutter application and its native macOS and Windows integrations is available in this repository for transparency. Usage and redistribution remain governed by the included `LICENSE`.

## Windows Build

Every relevant push to `main` starts the **Build Windows** GitHub Actions workflow. Its `Screen2Story-Windows` artifact contains a portable ZIP with `Screen2Story.exe` and all required runtime files. Flutter or Visual Studio are not required on the destination computer.

## Version

Current release: **v1.0.0**
