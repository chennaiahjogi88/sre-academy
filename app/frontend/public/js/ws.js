// WebSocket / Socket.io client
const WS = {
  socket: null,
  handlers: {},

  init: () => {
    if (WS.socket) return;
    const token = Auth.getToken();
    WS.socket = io({ auth: { token }, transports: ['websocket', 'polling'] });

    WS.socket.on('connect', () => {
      console.log('🔌 WebSocket connected');
      WS._emit('connect');
    });

    WS.socket.on('active_users', (data) => {
      WS._emit('active_users', data);
      // Update any active user display
      const el = document.getElementById('active-users-count');
      if (el) el.textContent = data.count;
    });

    WS.socket.on('announcement', (data) => {
      WS._emit('announcement', data);
      WS.showAnnouncementToast(data);
    });

    WS.socket.on('disconnect', () => WS._emit('disconnect'));
  },

  on: (event, handler) => {
    if (!WS.handlers[event]) WS.handlers[event] = [];
    WS.handlers[event].push(handler);
  },

  _emit: (event, data) => {
    (WS.handlers[event] || []).forEach(h => h(data));
  },

  sendProgress: (class_id, current_slide, total_slides) => {
    if (WS.socket) WS.socket.emit('slide_progress', { class_id, current_slide, total_slides });
  },

  sendAnnouncement: (title, message, type = 'info') => {
    if (WS.socket) WS.socket.emit('send_announcement', { title, message, type });
  },

  showAnnouncementToast: (data) => {
    const colors = { info: '#38bdf8', warning: '#fbbf24', success: '#4ade80', error: '#f87171' };
    const color = colors[data.type] || '#38bdf8';
    const toast = document.createElement('div');
    toast.style.cssText = `position:fixed;top:20px;right:20px;z-index:9999;background:#0f172a;border:1px solid ${color};border-left:4px solid ${color};border-radius:10px;padding:16px 20px;max-width:380px;box-shadow:0 8px 32px rgba(0,0,0,.5);animation:slideIn .3s ease`;
    toast.innerHTML = `
      <div style="font-size:13px;font-weight:700;color:${color};margin-bottom:4px">📢 ${data.title}</div>
      <div style="font-size:13px;color:#94a3b8;line-height:1.5">${data.message}</div>
      <div style="font-size:11px;color:#475569;margin-top:8px">from ${data.creator_name || 'Admin'}</div>`;
    document.body.appendChild(toast);
    setTimeout(() => { toast.style.opacity = '0'; toast.style.transition = 'opacity .5s'; setTimeout(() => toast.remove(), 500); }, 6000);
  },
};

window.WS = WS;
