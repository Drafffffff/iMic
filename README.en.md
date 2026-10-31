<div align="center">

# iMic

**Hold to speak, release to type.**

Your iPhone, your Mac's microphone. Release when done and your words land in any app you're using.

[中文](README.md) · [Website](https://drafffffff.github.io/iMic/en/) · [Get the Mac app](https://github.com/Drafffffff/iMic/releases/latest) · [Feedback](https://github.com/Drafffffff/iMic/issues)

<img src="docs/media/demo.gif" alt="Hold to speak on iPhone, see words appear on Mac, then pull the string down to send polished text" width="720">

</div>

## What it does

- **Hold to speak, release to type**: text lands at your Mac's cursor, anywhere you can type.
- **String gestures**: pull down for Return, up to delete, or sideways to move the cursor.
- **AI polish**: tidy spoken words into writing, or convert them into terminal commands, classical prose, and more.
- **Privacy**: your iPhone connects directly to your own Mac, without a relay server.

## Get started

You'll need a Mac with macOS 13+, an iPhone with iOS 17+, and your own [Model Studio (Bailian) API Key](https://modelstudio.console.alibabacloud.com/ap-southeast-1/model/settings/api-key). Connect both devices to the same Wi-Fi.

1. **Mac**: download the [latest DMG](https://github.com/Drafffffff/iMic/releases/latest), drag iMic into Applications, and open it. Follow setup to enter your Key and allow Accessibility. Use Alibaba Cloud's international Model Studio console, select **Singapore**, and create a pay-as-you-go Key with **All** permissions. Token Plan and Coding Plan Keys do not work with iMic. Eligible international Singapore models have a new-user quota; check your console for limits and enable Free Quota Only to stop when it runs out. Otherwise usage is billed automatically.
2. **iPhone**: the TestFlight beta is coming soon. Get it from the [website](https://drafffffff.github.io/iMic/en/#download) when available.
3. **Pair**: choose your Mac on iPhone and enter the 6-digit pairing code shown on your Mac.
4. **Type**: click a text field on your Mac, hold the orange bar at the bottom of your iPhone to speak, then release.

Need help? Read the [website FAQ](https://drafffffff.github.io/iMic/en/#faq). Developers can use the [development guide](https://github.com/Drafffffff/iMic/blob/codex/ui-phosphor-wireframe/docs/DEVELOPMENT.md).

GPL-3.0 · [Privacy notice](https://github.com/Drafffffff/iMic/blob/codex/ui-phosphor-wireframe/docs/PRIVACY.md)
