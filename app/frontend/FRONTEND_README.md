# Ktech SRE Training Platform — Frontend

A polished, production-quality SPA frontend for the SRE Training Platform with dark theme, real-time WebSocket support, and comprehensive admin controls.

## Architecture Overview

```
frontend/
├── Dockerfile                 # Multi-stage build (Node builder → nginx)
├── nginx.conf                # Reverse proxy config for /api & /socket.io
├── public/
│   ├── index.html            # Public landing page
│   ├── login.html            # Login page
│   ├── register.html         # Registration page
│   ├── portal.html           # Main student portal (requires auth)
│   ├── recordings.html       # Video recordings (requires auth)
│   ├── admin.html            # Admin dashboard (requires admin role)
│   ├── js/
│   │   ├── auth.js           # JWT & auth utilities
│   │   └── ws.js             # Socket.io client wrapper
│   └── ppts/                 # Presentation files (48 classes)
```

## Page Guide

### 1. **index.html** — Public Landing Page
- **Purpose:** Showcase the platform, attract new students
- **Features:**
  - Sticky navigation with "Ktech SRE" brand
  - Hero section with CTA ("Get Started — Login")
  - Stats row: 48 Classes, 10 Modules, 15+ Tools, Jan 2026 Batch
  - Free classes preview: SRE Foundations 1 & 2 (clickable, open PPTs)
  - Locked modules grid (10 modules with 🔒 overlay)
  - Tools grid: Prometheus, Grafana, Loki, Jaeger, Alertmanager, etc.
  - Footer with CTA
- **Auth:** None required (public)
- **Styling:** Dark theme (#060d1a bg, #38bdf8 accent)

### 2. **login.html** — Student & Admin Login
- **Purpose:** Authenticate users
- **Features:**
  - Centered card design
  - Email + Password fields
  - Error/success messages
  - Loading spinner on button
  - Demo credentials displayed below form:
    - Admin: `admin@ktech.sre` / `Admin@123`
    - Student: `student@ktech.sre` / `Student@123`
  - Calls `POST /api/auth/login`
  - Stores token + user in localStorage via `Auth.setSession()`
  - Redirects to `/portal.html` or `?next=` param
- **Auth:** None required (public)

### 3. **register.html** — New User Registration
- **Purpose:** Self-service account creation
- **Features:**
  - Name, email, password fields
  - Password requirements validator with visual feedback
    - 8+ characters
    - Upper + lowercase mix
    - At least one digit
  - Confirm password matching
  - Calls `POST /api/auth/register`
  - Auto-login on success
  - Redirects to portal
- **Auth:** None required (public)

### 4. **portal.html** — Main Student Portal
- **Purpose:** Class browsing, progress tracking, announcements
- **Features:**
  - **Navigation:**
    - Brand logo + "Ktech SRE"
    - Active users indicator (live via WebSocket): "🔴 X online"
    - User info card with role badge
    - Links: Recordings, Admin (if admin), Logout
  - **Hero Section:** "Welcome back, {name}!" + batch info
  - **Progress Bar:** Shows X/48 classes completed
  - **Announcements Banner:** Auto-fetched, dismissible, realtime updates via WebSocket
  - **Class Cards (All 48):**
    - Organized by module (10 sections)
    - Shows: Class #, title, topics, progress %, completion badge
    - Clickable: Opens PPT file at `/ppts/{file}`
    - Progress tracking: fetched from `/api/classes/progress/all`
  - **Real-time Features:**
    - WebSocket init on load
    - Active users count updates via `WS.on('active_users')`
    - Announcements arrive as toasts via `WS.on('announcement')`
- **Auth:** Required (`Auth.requireAuth()`)
- **Admin Only:** Admin panel link shown if `Auth.isAdmin()`

### 5. **recordings.html** — Video Recordings Library
- **Purpose:** Watch recorded class sessions
- **Features:**
  - **Navigation:** Same as portal
  - **Filter Bar:**
    - Dropdown: Filter by Module
    - Dropdown: Filter by Class
    - Upload button (admin only)
  - **Recording Cards:**
    - Video player (HTML5 `<video>`)
    - Title, class label, duration, upload date
    - Stream via `src="/api/recordings/stream/{filename}"`
    - Hover shows play button
  - **Admin Upload Modal:**
    - Class selector
    - Title + Description fields
    - File picker (video files only)
    - Progress bar (XHR upload tracking)
    - POST to `/api/recordings/upload` (multipart/form-data)
  - **Empty State:** "No recordings uploaded yet"
- **Auth:** Required
- **Admin Only:** Upload button

### 6. **admin.html** — Admin Dashboard
- **Purpose:** System management, user admin, announcements, observability
- **Features:**
  - **Navigation:** Admin badge, Back to Portal link
  - **Stats Cards (6):**
    - Total Users
    - Active Sessions
    - WS Connections (live)
    - Classes Completed
    - Recordings
    - Announcements
  - **Users Table:**
    - Name, Email, Role, Status, Last Login
    - Actions: Toggle Active/Disabled, Change Role
    - Calls `/api/admin/users/{id}/toggle`, `/api/admin/users/{id}/role`
  - **Announcements Section:**
    - Form: Title, Type (info/warning/success/error), Message
    - Submit: POST `/api/announcements` + broadcast via WebSocket
    - List: Shows all active announcements with delete buttons
  - **Recording Upload:**
    - Class selector, Title, Description, File picker
    - Same upload flow as recordings page
  - **Observability Links:**
    - Grafana (localhost:3000)
    - Prometheus (localhost:9090)
    - /metrics endpoint
- **Auth:** Required + admin role check
- **Redirect:** Non-admins sent to `/portal.html`

## Design System

### Colors
- **Background:** `#060d1a` (deep dark navy)
- **Secondary Bg:** `#0a1628` (card backgrounds)
- **Tertiary Bg:** `#0f172a` (hover/form inputs)
- **Accent:** `#38bdf8` (cyan/sky blue)
- **Accent Hover:** `#0ea5e9` (brighter blue)
- **Borders:** `#1e293b` (dark slate)
- **Text Primary:** `#e2e8f0` (off-white)
- **Text Secondary:** `#94a3b8` (slate-400)
- **Text Tertiary:** `#64748b` (slate-500)
- **Success:** `#4ade80` (green)
- **Warning:** `#fbbf24` (amber)
- **Error:** `#f87171` (red)

### Typography
- **Font:** System fonts: `-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto...`
- **Headings:** 700-800 weight, line-height 1.2
- **Body:** 400 weight, line-height 1.6
- **Labels:** 600 weight, uppercase, 0.2-0.5px letter-spacing

### Components
- **Buttons:** Rounded 6-8px, uppercase labels, smooth transitions
- **Cards:** 1px border #1e293b, rounded 10-12px, hover border glow
- **Inputs:** 10-12px padding, 6px radius, focus shadow with accent
- **Tables:** Clean rows, hover backgrounds, uppercase headers
- **Badges:** Inline, 4-8px padding, colored backgrounds

## Key Features

### Authentication & Authorization
- **JWT-based:** Token stored in localStorage
- **Guards:** `Auth.requireAuth()` redirects unauthenticated users
- **Role-based:** `Auth.isAdmin()` checks for admin access
- **Logout:** Clears session + redirects to landing page
- **Auto-logout:** 401 responses clear session automatically

### Real-time Updates (WebSocket/Socket.io)
- **Connection:** Auto-init via `WS.init()` on authenticated pages
- **Events:**
  - `active_users`: Updates live user count
  - `announcement`: Shows toast notification + banner
  - `slide_progress`: Tracks which slides users are viewing
- **Broadcast:** Admins can send announcements, updates propagate in real-time

### Progress Tracking
- **Per-user:** Fetched from `/api/classes/progress/all`
- **Display:** Progress % per card, completion badge
- **Update:** When user views PPT, progress sent via WebSocket

### Responsive Design
- **Breakpoints:**
  - `max-width: 1024px`: 2-col grids, adjust padding
  - `max-width: 768px`: 1-col stacked layout, mobile nav
  - `max-width: 640px`: Small devices, font reductions
- **Nav:** Sticky on desktop, collapsible on mobile
- **Tables:** Overflow-x on small screens

## API Integration Points

| Page | Method | Endpoint | Purpose |
|------|--------|----------|---------|
| login.html | POST | `/api/auth/login` | Authenticate user |
| register.html | POST | `/api/auth/register` | Create account |
| portal.html | GET | `/api/classes` | Fetch all 48 classes |
| portal.html | GET | `/api/classes/progress/all` | Get user progress |
| portal.html | GET | `/api/announcements` | Fetch latest announcements |
| recordings.html | GET | `/api/recordings` | List recordings |
| recordings.html | GET | `/api/recordings/stream/{filename}` | Stream video |
| recordings.html | POST | `/api/recordings/upload` | Upload recording |
| admin.html | GET | `/api/admin/stats` | Dashboard stats |
| admin.html | GET | `/api/admin/users` | User list |
| admin.html | PATCH | `/api/admin/users/{id}/toggle` | Toggle user active |
| admin.html | PATCH | `/api/admin/users/{id}/role` | Change role |
| admin.html | POST | `/api/announcements` | Create announcement |
| admin.html | DELETE | `/api/announcements/{id}` | Delete announcement |

## Utility Scripts

### **js/auth.js**
Manages JWT tokens and authentication state.

**Functions:**
- `Auth.getToken()` — Get JWT from localStorage
- `Auth.getUser()` — Parse user object from localStorage
- `Auth.setSession(token, user)` — Store token + user data
- `Auth.clearSession()` — Remove auth data
- `Auth.isLoggedIn()` — Check if authenticated
- `Auth.isAdmin()` — Check if user is admin
- `Auth.requireAuth()` — Guard: redirect to login if needed
- `Auth.redirectIfLoggedIn()` — Redirect already-logged-in users to portal
- `Auth.fetch(url, options)` — Fetch with Authorization header + 401 handling
- `Auth.logout()` — Clear session + redirect to landing page

### **js/ws.js**
WebSocket (Socket.io) client wrapper for real-time updates.

**Functions:**
- `WS.init()` — Connect to Socket.io with auth token
- `WS.on(event, handler)` — Register event listener
- `WS.sendProgress(class_id, current_slide, total_slides)` — Emit slide progress
- `WS.sendAnnouncement(title, message, type)` — Broadcast announcement
- `WS.showAnnouncementToast(data)` — Display toast notification

**Events:**
- `connect` — Socket connected
- `active_users` — Live user count
- `announcement` — New announcement received
- `disconnect` — Socket disconnected

## Docker & Nginx

### Dockerfile
```dockerfile
FROM node:20-alpine AS builder
WORKDIR /build
COPY public/ ./

FROM nginx:alpine
COPY --from=builder /build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

**Build Process:**
1. Builder stage: Copy `public/` files
2. Final stage: Copy to nginx, expose port 80
3. Gzip enabled for CSS/JS/JSON
4. Proxies `/api/` and `/socket.io/` to backend:3001

### nginx.conf
- **Gzip:** Enabled for text, CSS, JavaScript
- **API Proxy:** `/api/` → `http://backend:3001/api/`
- **WebSocket:** `/socket.io/` → `http://backend:3001/socket.io/` (upgrade headers)
- **Metrics:** `/metrics` → `http://backend:3001/metrics`
- **PPT Files:** Served directly from `/ppts/`
- **SPA Fallback:** Non-PPT routes return 404 (single-page app)

## Development Notes

### No Build Step Required
All files are self-contained HTML with inline CSS and scripts. No webpack, bundler, or build process needed. Drop into nginx and serve.

### File Sizes
- index.html: ~20 KB
- login.html: ~13 KB
- register.html: ~13 KB
- portal.html: ~20 KB
- recordings.html: ~30 KB
- admin.html: ~31 KB
- auth.js: ~1 KB
- ws.js: ~2 KB

### Browser Requirements
- Modern browser with ES6+ support
- WebSocket support
- localStorage API
- HTML5 video element (for recordings)

### Testing Credentials
```
Admin:
  Email: admin@ktech.sre
  Password: Admin@123

Student:
  Email: student@ktech.sre
  Password: Student@123
```

## Future Enhancements
- Offline support with service workers
- Dark/light mode toggle
- Mobile app PWA
- Advanced analytics dashboard
- Certificate generation
- Discussion forums
- Peer code review interface

---

Built with care for the Ktech SRE Training Platform, Jan 2026 Batch.
