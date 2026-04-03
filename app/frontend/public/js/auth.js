// Auth utility — JWT storage and guards
const Auth = {
  getToken: () => localStorage.getItem('sre_token'),
  getUser: () => {
    const raw = localStorage.getItem('sre_user');
    return raw ? JSON.parse(raw) : null;
  },
  setSession: (token, user) => {
    localStorage.setItem('sre_token', token);
    localStorage.setItem('sre_user', JSON.stringify(user));
  },
  clearSession: () => {
    localStorage.removeItem('sre_token');
    localStorage.removeItem('sre_user');
  },
  isLoggedIn: () => !!localStorage.getItem('sre_token'),
  isAdmin: () => {
    const u = Auth.getUser();
    return u && u.role === 'admin';
  },

  // Redirect to login if not authenticated
  requireAuth: (redirectBack = true) => {
    if (!Auth.isLoggedIn()) {
      const path = redirectBack ? '?next=' + encodeURIComponent(window.location.pathname) : '';
      window.location.href = '/login.html' + path;
      return false;
    }
    return true;
  },

  // Redirect to portal if already logged in
  redirectIfLoggedIn: () => {
    if (Auth.isLoggedIn()) {
      const params = new URLSearchParams(window.location.search);
      window.location.href = params.get('next') || '/portal.html';
    }
  },

  // API call helper with auth header
  fetch: async (url, options = {}) => {
    const token = Auth.getToken();
    const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    const res = await fetch(url, { ...options, headers });
    if (res.status === 401) {
      Auth.clearSession();
      window.location.href = '/login.html';
      return null;
    }
    return res;
  },

  logout: async () => {
    try { await Auth.fetch('/api/auth/logout', { method: 'POST' }); } catch (_) {}
    Auth.clearSession();
    window.location.href = '/index.html';
  },
};

window.Auth = Auth;
