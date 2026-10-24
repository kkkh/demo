# Yuanshu — Shanxi Jinzhong Institute of Technology App

"Yuanshu" is the official iOS application of Shanxi Jinzhong Institute of Technology, developed based on SwiftUI, providing teachers, students, and visitors with one-stop services such as campus news, notifications, organizational navigation, and the Principal's Mailbox.

## Features

### 📱 Core Modules
- **Home** - Carousel banners, campus statistics, shortcut entries, campus highlights, etc.
- **News** - Browsing by category including important news, announcements, admission information, etc.
- **Campus** - Campus calendar, activities, scenery, facilities, faculty showcase
- **Organization** - Departmental organizational structure, supports deep article search
- **Me** - Personal center, bookmark management, message center, settings

### 🆕 New Features (2026-09-24)
- **Message Center** - In-app notification box, unified management of various push messages
- **Campus Calendar** - Native module displaying campus calendar articles
- **Usage Help** - Replaced "Campus Highlights" entry on the home page with a Usage Help anchor
- **Principal's Mailbox** - Native module supporting viewing messages and replies
- **Party Building Special** - Aggregated browsing of party building articles
- **School Overview** - School introduction, leadership team, scenery album, external cooperation

### ⚙️ Settings & Personalization
- **Display Settings** - Appearance mode (Light/Dark/Follow System), theme style, font size, line spacing, character spacing, article text color, reading statistics, etc.
- **Cache Mode** - Smart cache, data saving mode, image data-free usage
- **Notification Management** - Push permissions, polling interval, custom notifications
- **Biometric Authentication** - Face ID / Touch ID app lock
- **App Icon** - Supports switching between multiple icon sets

### 🌐 Network & Debugging
- **Network Monitoring** - Real-time network status, traffic statistics, latency analysis, network health check, speed test

## Technical Architecture

### Directory Structure
```
qin/
├── DesignCode/                 # Main Source Code Directory
│   ├── DesignCodeApp.swift     # App Entry Point
│   ├── TabBar.swift            # Main Navigation (9107 lines, 60+ views)
│   ├── DataService.swift       # Data Hub
│   ├── NetworkService.swift    # Network Layer
│   ├── Models.swift            # Data Models
│   └── [Other Module Files]
├── DesignCodeTests/            # Unit Tests
├── ARCHITECTURE.md             # Architecture Documentation
├── CODE_WIKI.md                # Code Encyclopedia
└── docs/                       # Flowchart Documentation
```

### Tech Stack
- **UI Framework**: SwiftUI
- **Target iOS**: iOS 17+
- **Architecture Pattern**: MVVM + Singleton Store
- **State Management**: @Published / @ObservedObject / @AppStorage
- **Network**: URLSession + async/await
- **Persistence**: UserDefaults + File Storage + NSCache

### Key Design
- **Data Degradation**: Three-tier degradation strategy (Memory → Disk → Static Fallback)
- **Unified Image Loading**: SJZCachedImage component, zero-flicker core
- **Logging System**: LogManager, supports file persistence and crash capture
- **Deep Links**: Five categories of DeepLink crash prevention design

## Build & Run

### Environment Requirements
- macOS + Xcode 15+
- iOS 17+ device or simulator

### Build Settings
- **SDKROOT**: iphoneos
- **Code Sign**: Requires Apple Developer Team signature
- **Deployment Target**: iOS 17.0

### Run Methods

**Real Device Build** (Requires signature):
```bash
# Select target device in Xcode and run
```

**Simulator Verification**:
```bash
# Select simulator in Xcode and run
```

**Unit Tests**:
```bash
# Recommended to run on real device, currently 54 test cases all green
```

## Project Structure

### Core Manager/Store Overview
| Module | File | Description |
|------|------|------|
| Data Hub | DataService.swift | Unified data synchronization and caching |
| Network Layer | NetworkService.swift | API request encapsulation |
| Logging | LogManager.swift | Unified log output |
| Display Settings | DisplaySettingsManager.swift | Visual personalization |
| Cache Mode | CacheModeManager.swift | Data and image caching |
| Biometric Security | BiometricSecurityManager.swift | Face ID/Touch ID |
| Home Module | HomeModuleManager.swift | Module visibility management |
| Notification System | NotificationManager.swift | Push and polling |
| Bookmarks | BookmarkManager.swift | Saved article management |
| Read Status | ReadStatusManager.swift | Read markers |
| Organization Module | OrganizationManager.swift | Department data |
| Network Monitor | SJZNetworkMonitor.swift | Real-time network status |

### Data Models
- `NewsItem` - News Articles
- `Banner` - Carousel Images
- `Department` - Departments and Majors
- `CampusActivity` - Campus Activities
- `CampusVideo` - Campus Videos
- `Facility` - Campus Facilities
- `BookmarkItem` - Bookmark Items

## Documentation

- [ARCHITECTURE.md](qin/ARCHITECTURE.md) - Complete architecture documentation
- [CODE_WIKI.md](qin/CODE_WIKI.md) - Code encyclopedia and module details
- [DEBUG_REPORT.md](qin/DEBUG_REPORT.md) - Data synchronization troubleshooting report
- `.trae/documents/` - Various implementation plans and specifications

## Notes

### Engineering Constraints
1. Hardcoding addresses other than online API domains is prohibited
2. All network requests must pass through NetworkService unified encapsulation
3. Image loading must use the SJZCachedImage component
4. New logs must integrate with LogManager
5. Push messages must support silent processing

### Known Risks
- Some third-party interfaces may exist instability
- Offline fallback is required in weak network environments

## License

This project is owned by Shanxi Jinzhong Institute of Technology and is for learning and internal use only.

---

*For more technical details, please refer to [CODE_WIKI.md](qin/CODE_WIKI.md) and [ARCHITECTURE.md](qin/ARCHITECTURE.md)*