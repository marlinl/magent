const state = {
  running: true,
  mode: 'Rule',
  node: 'Hong Kong 01',
  latency: '34ms',
  toastTimer: null
};

const pageMeta = {
  dashboard: {
    eyebrow: '概览',
    title: '代理链路总览',
    copy: '把连接状态、当前节点、本地端口和规则命中放在一个屏幕内，打开后 3 秒内判断代理是否可用。'
  },
  nodes: {
    eyebrow: '节点',
    title: '节点管理与测速',
    copy: '添加、选择、编辑和测速 Shadowsocks 节点；当前节点会驱动代理启动链路。'
  },
  policy: {
    eyebrow: '策略',
    title: '分流规则与连通性测试',
    copy: '按顺序管理 DIRECT、PROXY 和指定节点动作，并验证当前代理链路是否可用。'
  },
  activity: {
    eyebrow: '活动',
    title: '连接日志与诊断',
    copy: '查看最近请求如何被规则命中，并快速定位节点、端口或系统代理问题。'
  },
  settings: {
    eyebrow: '设置',
    title: '本地端口与启动偏好',
    copy: '维护低频配置，避免把启动代理和修改配置混在同一个动作里。'
  }
};

const dashboardActions = document.getElementById('pageActions').innerHTML;

function qs(selector, root = document) {
  return root.querySelector(selector);
}

function qsa(selector, root = document) {
  return Array.from(root.querySelectorAll(selector));
}

function showToast(message) {
  const toast = qs('#toast');
  qs('#toastText').textContent = message;
  toast.classList.add('show');
  clearTimeout(state.toastTimer);
  state.toastTimer = setTimeout(() => toast.classList.remove('show'), 1800);
}

function setPanel(panelId) {
  qsa('.panel').forEach(panel => panel.classList.toggle('active', panel.id === panelId));
  qsa('.nav button').forEach(button => button.classList.toggle('active', button.dataset.panel === panelId));

  const meta = pageMeta[panelId];
  qs('#pageEyebrow').textContent = meta.eyebrow;
  qs('#pageTitle').textContent = meta.title;
  qs('#pageCopy').textContent = meta.copy;

  qs('#pageActions').innerHTML = panelId === 'dashboard'
    ? dashboardActions
    : '<button class="mx-button" data-action="copy-endpoint">复制端点</button><button class="mx-button danger" data-action="stop-all">停止全部</button>';

  syncView();
}

function syncView() {
  qs('#sidebarNode').textContent = state.node;
  qs('#sidebarMode').textContent = state.mode;
  qs('#routeNode').textContent = state.node;
  qs('#detailNode').textContent = state.node;
  qs('#detailLatency').textContent = state.latency;

  qs('#statusHero').classList.toggle('stopped', !state.running);
  qs('#sidebarDot').classList.toggle('live', state.running);
  qs('#sidebarStatus').textContent = state.running ? '运行中' : '已停止';
  qs('#statusTitle').textContent = state.running ? '代理已连接' : '代理已断开';
  qs('#statusMeta').textContent = state.running
    ? `${state.mode} 模式 · ${state.node} · ${state.latency}`
    : '本地服务已停止，应用将直连网络';
  qs('#statusPill').className = state.running ? 'mx-pill green' : 'mx-pill';
  qs('#statusPill').innerHTML = state.running
    ? '<span class="mx-dot live"></span> Protected'
    : '<span class="mx-dot"></span> Offline';
  qs('#downloadRate').textContent = state.running ? '12.8 MB/s' : '0 KB/s';
  qs('#uploadRate').textContent = state.running ? '2.1 MB/s' : '0 KB/s';

  const runningServices = qsa('[data-service].on').length;
  const summary = qs('#serviceSummary');
  summary.textContent = `${runningServices}/2 运行`;
  summary.className = runningServices === 2 ? 'mx-pill green' : runningServices === 1 ? 'mx-pill amber' : 'mx-pill';

  qsa('[data-action="toggle-connect"]').forEach(button => {
    button.textContent = state.running ? '断开连接' : '连接';
    button.className = state.running ? 'mx-button success' : 'mx-button primary';
  });

  qsa('[data-mode]').forEach(button => button.classList.toggle('active', button.dataset.mode === state.mode));
}

function runLatencyTest(targets) {
  targets.forEach(target => {
    target.textContent = '测速中';
    target.className = 'mx-pill amber latency';
  });

  setTimeout(() => {
    targets.forEach((target, index) => {
      const value = index % 3 === 0 ? '32ms' : index % 3 === 1 ? '58ms' : '91ms';
      target.textContent = value;
      target.className = value === '91ms' ? 'mx-pill amber latency' : 'mx-pill green latency';
    });

    const selectedLatency = qs('.node-card.selected .latency');
    if (selectedLatency) state.latency = selectedLatency.textContent;
    showToast('节点测速完成');
    syncView();
  }, 700);
}

function addRule() {
  const tbody = qs('#policyTable tbody');
  const finalRule = tbody.lastElementChild;
  const index = String(tbody.children.length + 1).padStart(2, '0');
  const row = document.createElement('tr');
  row.innerHTML = [
    `<td>${index}</td>`,
    '<td>New Rule</td>',
    '<td>Domain Suffix</td>',
    '<td class="mx-mono truncate">example.com</td>',
    '<td><span class="mx-pill violet">PROXY</span></td>',
    '<td><button class="mx-button mx-icon-button" data-action="delete-rule" title="删除">D</button></td>'
  ].join('');
  tbody.insertBefore(row, finalRule);
  showToast('已新增一条规则');
}

function handleAction(action, actionElement) {
  if (action === 'toggle-connect') {
    state.running = !state.running;
    qsa('[data-service]').forEach(button => button.classList.toggle('on', state.running));
    showToast(state.running ? '代理服务已启动' : '代理服务已停止');
    syncView();
  }

  if (action === 'stop-all') {
    state.running = false;
    qsa('[data-service]').forEach(button => button.classList.remove('on'));
    showToast('SOCKS5 和 HTTP 已全部停止');
    syncView();
  }

  if (action === 'copy-endpoint') showToast('已复制 127.0.0.1:1080 / 7890');
  if (action === 'sync') showToast('订阅已同步，节点和规则已刷新');
  if (action === 'open-policy') setPanel('policy');
  if (action === 'save-node') showToast('节点配置已保存');
  if (action === 'save-settings') showToast('本地端口设置已保存');
  if (action === 'new-rule') addRule();

  if (action === 'delete-rule') {
    const row = actionElement.closest('tr');
    if (!row) return;
    const isFinal = row.cells[1]?.textContent === 'Final Rule';
    if (isFinal) {
      showToast('Final Rule 需要保留');
      return;
    }
    row.remove();
    showToast('规则已删除');
  }

  if (action === 'run-test') {
    const result = qs('#testResult');
    result.textContent = '测试中';
    result.className = 'mx-pill amber';
    setTimeout(() => {
      result.textContent = state.running ? '204 · 36ms' : '代理未运行';
      result.className = state.running ? 'mx-pill green' : 'mx-pill amber';
      showToast(state.running ? '连通性测试通过' : '请先启动本地代理');
    }, 700);
  }

  if (action === 'test-current') {
    const target = qs('.node-card.selected .latency');
    if (target) runLatencyTest([target]);
  }

  if (action === 'test-all') {
    runLatencyTest(qsa('.latency'));
  }

  if (action === 'new-node' || action === 'edit-node') {
    qs('#sheetTitle').textContent = action === 'new-node' ? '新增节点' : '编辑节点';
    qs('#nodeSheet').classList.add('show');
  }

  if (action === 'close-sheet') qs('#nodeSheet').classList.remove('show');

  if (action === 'confirm-sheet') {
    state.node = qs('#sheetName').value.trim() || 'New Node';
    state.latency = '未测速';
    qs('#nodeSheet').classList.remove('show');
    showToast(`已保存并选择 ${state.node}`);
    syncView();
  }
}

document.addEventListener('click', event => {
  const nav = event.target.closest('.nav button');
  if (nav) setPanel(nav.dataset.panel);

  const modeButton = event.target.closest('[data-mode]');
  if (modeButton) {
    state.mode = modeButton.dataset.mode;
    showToast(`已切换到 ${state.mode} 模式`);
    syncView();
  }

  const switchButton = event.target.closest('.mx-switch');
  if (switchButton) {
    switchButton.classList.toggle('on');
    if (switchButton.dataset.service) {
      state.running = qsa('[data-service].on').length > 0;
    }
    syncView();
  }

  const nodeCard = event.target.closest('.node-card');
  if (nodeCard) {
    qsa('.node-card').forEach(card => card.classList.remove('selected'));
    nodeCard.classList.add('selected');
    state.node = nodeCard.dataset.node;
    state.latency = nodeCard.dataset.latency;
    showToast(`当前节点：${state.node}`);
    syncView();
  }

  const actionElement = event.target.closest('[data-action]');
  if (actionElement) handleAction(actionElement.dataset.action, actionElement);
});

qsa('[data-filter]').forEach(button => {
  button.addEventListener('click', () => {
    qsa('[data-filter]').forEach(item => item.classList.toggle('active', item === button));
    const filter = button.dataset.filter;
    qsa('.log-row').forEach(row => {
      row.classList.toggle('hidden', filter !== 'all' && row.dataset.kind !== filter);
    });
  });
});

qs('#globalSearch').addEventListener('input', event => {
  const term = event.target.value.trim().toLowerCase();
  if (!term) {
    qsa('.log-row').forEach(row => row.classList.remove('hidden'));
    return;
  }
  setPanel('activity');
  qsa('.log-row').forEach(row => {
    row.classList.toggle('hidden', !row.textContent.toLowerCase().includes(term));
  });
});

setInterval(() => {
  if (!state.running) return;
  qsa('.mini-bar').forEach(bar => {
    bar.style.setProperty('--height', `${24 + Math.round(Math.random() * 64)}%`);
  });
}, 1600);

syncView();
