# App Store Images

Place screenshots and icons here for F-Droid listing.

## Expected structure

```
images/
├── icon.png                    # App icon (512x512 PNG)
├── featureGraphic.png          # Feature graphic (1024x500 PNG)
├── phoneScreenshots/
│   ├── 1.png                   # Screenshot 1
│   ├── 2.png                   # Screenshot 2
│   └── ...
└── sevenInchScreenshots/       # Optional: 7-inch tablet screenshots
    └── ...
```

## Guidelines

- **icon.png**: 512x512 pixels, PNG format
- **featureGraphic.png**: 1024x500 pixels, PNG format (displayed at top of F-Droid listing)
- **phoneScreenshots/**: Phone screenshots, recommended 1080x1920 or similar portrait ratio
- Screenshots should showcase key features: home screen, archive creation, tag writing, restore flow
- F-Droid will pick up these images automatically during the build process
