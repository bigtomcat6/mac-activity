## 🔒 Security

- Harden DMG path handling. (#79)
- Harden appcast publishing workflow. (#80)
- Harden DMG packaging. (#81)

## ✨ Features

- Add GPU, VRAM metrics, temperature source selection, and dashboard improvements. (#1)
- Add active app memory ranking dashboard. (#6)
- Memory stacked bars. (#8)
- Enhance memory visualization and refine temperature settings. (#9)
- Refine memory dashboard breakdown. (#10)
- Enhance memory UI and network sampling features. (#11)
- Implement actives cleanup services and remove outdated design document. (#12)
- Enhance actives cleanup and memory management features. (#13)
- Refactor and implement overview layout with new features. (#14)
- Enhance dashboard metrics handling and improve trend chart features. (#17)
- Add localization support for English and Simplified Chinese. (#19)
- Enhance memory and disk cleanup tools with debugging support. (#23)
- Refactor temperature functions to handle multiple sources. (#24)
- Enhance disk cleaning function with user-defined categories. (#26)
- Enhance Dashboard UI with new components, styles, and localization. (#27)
- Enhance dashboard with disk and swap metrics support. (#31)
- Implement hardware battery percentage features and preferences. (#34)
- Integrate Sparkle updates with secure appcast metadata and channels. (#51)
- Add storage detail icons and dynamic usage ordering. (#58)
- Add process display preferences for memory units and app identifiers. (#63)
- Improve dashboard card sizing and memory chart allocation. (#64)
- Improve storage usage metrics visibility and layout handling. (#65)
- Sync update channel with installed version and release tag. (#76)
- Localize runtime and dashboard language surfaces. (#77)
- Collapse update channel state when reopening preferences. (#90)
- Add German, French, Japanese, Korean, and Traditional Chinese localizations. (#93)

## 🐛 Bug Fixes

- Avoid double counting virtual network interfaces. (#7)
- Optimize and simplify x-axis date calculation for DashboardTrendChart. (#30)
- Update DMG volume name with app name and title. (#45)
- Update DMG creation to use Finder alias for Applications folder. (#60)
- Refactor RAM bucketing and inactive-memory sampling cadence. (#66)
- Use release tags for Sparkle version display. (#75)
- Update DMG installer layout and background styling. (#82)
- Hide swap percent in storage detail. (#87)

## ⚡ Performance

- Optimize DashboardTrendChart for sample display budget and tests. (#3)
- Refactor dashboard and preferences controllers with lazy initialization. (#4)
- Refines metric sampling intervals for different profiles, improves memory safety in popover handling. (#35)
- Improve localization caching for faster lookups. (#84)
- Improve RAM segment bar averaging and bucket grouping. (#91)

## Other Changes

- Add app icon and DMG packaging assets. (#42)
- Add prerelease validation to release planning. (#73)
- Add appcast publication script execution. (#74)

