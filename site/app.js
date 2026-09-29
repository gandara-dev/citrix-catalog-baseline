import {
  SEVERITIES,
  catalogByName,
  compareCatalogs,
  filterRows,
  lookupUsers,
  recommendationsFor,
  toCsv,
  validateReport,
} from './lib/review.js';

const $ = (id) => document.getElementById(id);
const state = { report: null, checked: new Set(), sort: {}, listFilter: '' };

// Everything in a report came from a file the user opened: escape it all.
const e = (value) => String(value ?? '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const plural = (count, word, many = `${word}s`) => `${count} ${count === 1 ? word : many}`;
const shortDate = (iso) => (iso ? iso.slice(0, 16).replace('T', ' ') : '');
const short = (name) => String(name || '').replace(/^[^\\]+\\/, '');
const severityRank = (severity) => SEVERITIES.indexOf(severity);

function notice(message) {
  $('notice').textContent = message || '';
  $('notice').hidden = !message;
}

function download(name, content) {
  const url = URL.createObjectURL(new Blob([content], { type: 'text/csv' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}

// ------------------------------------------------------------------ plain-language access

// Explains one access entry the way an admin would say it.
function why(entry) {
  const path = entry.path || [];
  let text;
  if (entry.grantedBy === 'Machine assignment') {
    text = `Assigned to <b>${e(short(entry.machine))}</b>`;
  } else if (path[1] === '(all users)') {
    text = `Rule <b>${e(entry.desktopRule)}</b> includes all users`;
  } else if (path.length <= 1) {
    text = `Named directly in rule <b>${e(entry.desktopRule)}</b>`;
  } else {
    const groups = path.slice(1).map((group) => `<b>${e(short(group))}</b>`);
    text = `Member of ${groups[0]}${groups.slice(1).map((group) => `, which is in ${group}`).join('')}; entitled by <b>${e(entry.desktopRule)}</b>`;
  }
  if (entry.machine && entry.grantedBy !== 'Machine assignment') text += `; machine <b>${e(short(entry.machine))}</b>`;
  if (entry.status === 'BlockedByAccessPolicy') text += ' — <span class="state-warn">blocked: no access policy rule allows the connection</span>';
  if (entry.status === 'DeliveryGroupDisabled') text += ' — <span class="state-warn">delivery group is disabled</span>';
  return text;
}
const whyText = (entry) => why(entry).replace(/<[^>]+>/g, '');
const statusCell = (status) => (status === 'Granted' ? '<span class="state-ok">Allowed</span>'
  : status === 'BlockedByAccessPolicy' ? '<span class="state-warn">Blocked</span>' : '<span class="state-warn">Group disabled</span>');
const accountCell = (enabled) => (enabled === false ? '<span class="state-bad">Disabled</span>' : 'Enabled');

// ------------------------------------------------------------------ grids

function sortRows(key, columns, rows) {
  const sort = state.sort[key];
  if (!sort) return rows;
  const column = columns[sort.index];
  if (!column) return rows;
  const value = (row) => (column.sort ? column.sort(row) : column.value(row));
  return [...rows].sort((a, b) => {
    const x = value(a);
    const y = value(b);
    const result = typeof x === 'number' && typeof y === 'number' ? x - y : String(x ?? '').localeCompare(String(y ?? ''), undefined, { numeric: true });
    return sort.desc ? -result : result;
  });
}

// A table with sortable headers, optional row selection and check boxes.
function grid(container, { key, columns, rows, selected, rowKey, onSelect, checkable, empty = 'Nothing to show.' }) {
  const sorted = sortRows(key, columns, rows);
  const sort = state.sort[key];
  const head = `${checkable ? '<th><span class="sr-only">Select</span></th>' : ''}${columns.map((column, index) =>
    `<th class="${column.num ? 'num' : ''}" data-sort="${index}" aria-sort="${sort?.index === index ? (sort.desc ? 'descending' : 'ascending') : 'none'}">${e(column.label)}${sort?.index === index ? (sort.desc ? ' ▾' : ' ▴') : ''}</th>`).join('')}`;
  const body = sorted.map((row) => {
    const id = rowKey ? rowKey(row) : null;
    const isSelected = id !== null && id === selected;
    return `<tr class="${onSelect ? 'selectable' : ''}" ${id !== null ? `data-key="${e(id)}"` : ''} aria-selected="${isSelected}" ${onSelect ? 'tabindex="0"' : ''}>
      ${checkable ? `<td><input type="checkbox" data-check="${e(id)}" ${state.checked.has(id) ? 'checked' : ''} aria-label="Select ${e(id)}"></td>` : ''}
      ${columns.map((column) => `<td class="${column.num ? 'num' : ''} ${column.wrap ? 'wrap' : ''}">${column.html ? column.html(row) : e(column.value(row))}</td>`).join('')}
    </tr>`;
  }).join('');
  container.innerHTML = rows.length
    ? `<table class="grid"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`
    : `<p class="empty">${e(empty)}</p>`;

  for (const th of container.querySelectorAll('th[data-sort]')) {
    th.style.cursor = 'pointer';
    th.addEventListener('click', () => {
      const index = Number(th.dataset.sort);
      const current = state.sort[key];
      state.sort[key] = { index, desc: current?.index === index ? !current.desc : false };
      grid(container, { key, columns, rows, selected, rowKey, onSelect, checkable, empty });
    });
  }
  if (onSelect) {
    const rowsEls = [...container.querySelectorAll('tr.selectable')];
    rowsEls.forEach((tr, index) => {
      tr.addEventListener('click', (event) => {
        if (event.target.closest('input, a')) return;
        onSelect(tr.dataset.key);
      });
      tr.addEventListener('keydown', (event) => {
        if (event.key === 'Enter') onSelect(tr.dataset.key);
        if (event.key === 'ArrowDown' && rowsEls[index + 1]) { event.preventDefault(); rowsEls[index + 1].focus(); onSelect(rowsEls[index + 1].dataset.key); }
        if (event.key === 'ArrowUp' && rowsEls[index - 1]) { event.preventDefault(); rowsEls[index - 1].focus(); onSelect(rowsEls[index - 1].dataset.key); }
      });
    });
    container.querySelector('tr[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' });
  }
  for (const box of container.querySelectorAll('[data-check]')) {
    box.addEventListener('change', () => {
      if (box.checked) state.checked.add(box.dataset.check);
      else state.checked.delete(box.dataset.check);
      renderListActions();
    });
  }
  return sorted;
}

// A details table with its own filter and CSV export.
function detailTable(container, { key, columns, rows, csvName, empty }) {
  container.innerHTML = `<div class="detail-filter"><input type="search" placeholder="Filter" aria-label="Filter"><span class="count"></span><span class="grow"></span><button type="button">Export CSV</button></div><div class="grid-wrap"></div>`;
  const input = container.querySelector('input');
  const wrap = container.querySelector('.grid-wrap');
  const render = () => {
    const visible = filterRows(rows.map((row) => ({ row, text: columns.map((column) => column.value(row)).join(' ') })), input.value, ['text']).map((item) => item.row);
    container.querySelector('.count').textContent = `${visible.length} of ${rows.length}`;
    return grid(wrap, { key, columns, rows: visible, empty });
  };
  input.addEventListener('input', render);
  container.querySelector('button').addEventListener('click', () => {
    download(csvName, toCsv(columns.map((column) => ({ label: column.label, value: column.value })), render()));
  });
  render();
}

// ------------------------------------------------------------------ data helpers

const findingsFor = (catalogName) => recommendationsFor(state.report, catalogName);
const worst = (items) => items.reduce((best, item) => (best === null || severityRank(item.severity) < severityRank(best) ? item.severity : best), null);
const problemsCell = (items) => (items.length ? `<span class="badge ${e(worst(items))}">${items.length}</span>` : '');
const groupFindings = (name) => state.report.recommendations.filter((item) =>
  item.evidence.some((row) => row.deliveryGroup === name || (row.kind === 'delivery group' && row.name === name)));
const userFindings = (name) => state.report.recommendations.filter((item) => item.evidence.some((row) => row.user === name));

function groupAccess(name) {
  const seen = new Map();
  for (const catalog of state.report.catalogs) {
    for (const entry of catalog.access) {
      if (entry.deliveryGroup === name && !seen.has(entry.user)) seen.set(entry.user, entry);
    }
  }
  if (seen.size) return [...seen.values()];
  // A delivery group without machines appears in no catalog; fall back to the user list.
  return state.report.users
    .filter((user) => user.deliveryGroups.includes(name) || user.blocked.some((item) => item.deliveryGroup === name))
    .map((user) => ({
      user: user.name,
      displayName: user.displayName,
      enabled: user.enabled,
      deliveryGroup: name,
      status: user.blocked.find((item) => item.deliveryGroup === name)?.status || 'Granted',
      path: [],
    }));
}

function userEntries(name) {
  return state.report.catalogs.flatMap((catalog) => catalog.access
    .filter((entry) => entry.user === name)
    .map((entry) => ({ ...entry, catalog: catalog.name })));
}

// ------------------------------------------------------------------ nodes

const NODES = {
  catalogs: {
    label: 'Machine Catalogs',
    icon: '▦',
    items: () => state.report.catalogs,
    key: (catalog) => catalog.name,
    checkable: true,
    columns: [
      { label: 'Machine catalog', value: (c) => c.name },
      { label: 'Machine type', value: (c) => `${c.provisioningType} · ${c.sessionSupport === 'MultiSession' ? 'Multi-session OS' : 'Single-session OS'}` },
      { label: 'Allocation', value: (c) => (c.allocationType === 'Static' ? 'Static' : 'Random') },
      { label: 'User data', value: (c) => (c.persistUserChanges === 'Discard' ? 'Discard' : 'On local disk') },
      { label: 'Machines', value: (c) => c.machineCount, num: true },
      { label: 'VDA', value: (c) => c.vdaVersions.map((v) => v.version).filter(Boolean).map((v) => v.split('.')[0]).join(', ') || '—' },
      { label: 'Delivery groups', value: (c) => c.deliveryGroups.join(', ') || '—' },
      { label: 'Problems', value: (c) => findingsFor(c.name).length, sort: (c) => findingsFor(c.name).length, html: (c) => problemsCell(findingsFor(c.name)), num: true },
    ],
    tabs: ['Details', 'Machines', 'Users', 'Software', 'Problems'],
    title: (c) => c.name,
    render: renderCatalog,
  },
  groups: {
    label: 'Delivery Groups',
    icon: '▤',
    items: () => state.report.deliveryGroups,
    key: (g) => g.name,
    columns: [
      { label: 'Delivery group', value: (g) => g.name },
      { label: 'Delivering', value: (g) => (g.desktopKind === 'Private' ? 'Assigned desktops' : 'Random desktops') },
      { label: 'State', value: (g) => (g.enabled ? 'Enabled' : 'Disabled'), html: (g) => (g.enabled ? 'Enabled' : '<span class="state-warn">Disabled</span>') },
      { label: 'Machine catalogs', value: (g) => g.catalogs.join(', ') || '—' },
      { label: 'Machines', value: (g) => g.machineCount, num: true },
      { label: 'Users', value: (g) => g.grantedUsers, num: true },
      { label: 'Problems', value: (g) => groupFindings(g.name).length, html: (g) => problemsCell(groupFindings(g.name)), num: true },
    ],
    tabs: ['Details', 'Users', 'Access policy', 'Machines'],
    title: (g) => g.name,
    render: renderGroup,
  },
  users: {
    label: 'Users',
    icon: '◉',
    items: () => state.report.users,
    key: (u) => u.name,
    columns: [
      { label: 'User', value: (u) => u.name },
      { label: 'Name', value: (u) => u.displayName || '' },
      { label: 'Account', value: (u) => (u.enabled === false ? 'Disabled' : 'Enabled'), html: (u) => accountCell(u.enabled) },
      { label: 'Desktops', value: (u) => u.deliveryGroups.length, num: true },
      { label: 'Machine catalogs', value: (u) => u.catalogs.join(', ') || '—' },
      { label: 'Blocked', value: (u) => u.blocked.length || '', num: true },
    ],
    tabs: ['Access', 'Problems'],
    title: (u) => `${e(u.name)}${u.displayName ? ` <small>${e(u.displayName)}</small>` : ''}`,
    render: renderUser,
  },
  problems: {
    label: 'Problems',
    icon: '⚠',
    items: () => state.report.recommendations.map((item, index) => ({ ...item, index: String(index + 1) })),
    key: (p) => p.index,
    columns: [
      { label: 'Severity', value: (p) => p.severity, sort: (p) => severityRank(p.severity), html: (p) => `<span class="badge ${e(p.severity)}">${e(p.severity)}</span>` },
      { label: 'Problem', value: (p) => p.title, wrap: true },
      { label: 'Affects', value: (p) => p.catalogs.join(', ') || '—', wrap: true },
      { label: 'Rule', value: (p) => p.id },
    ],
    tabs: ['Evidence'],
    title: (p) => p.title,
    render: renderProblem,
  },
};

// ------------------------------------------------------------------ details renderers

function props(pairs) {
  return `<dl class="props">${pairs.map(([label, value]) => `<div><dt>${e(label)}</dt><dd>${value}</dd></div>`).join('')}</dl>`;
}
const link = (node, name) => `<a href="#/${node}/${encodeURIComponent(name)}">${e(name)}</a>`;
const accessColumns = (withCatalog) => [
  { label: 'User', value: (a) => a.user, html: (a) => link('users', a.user) },
  { label: 'Name', value: (a) => a.displayName || '' },
  ...(withCatalog ? [{ label: 'Machine catalog', value: (a) => a.catalog }] : []),
  { label: 'Delivery group', value: (a) => a.deliveryGroup },
  { label: 'Access', value: (a) => a.status, html: (a) => statusCell(a.status) },
  { label: 'Account', value: (a) => (a.enabled === false ? 'Disabled' : 'Enabled'), html: (a) => accountCell(a.enabled) },
  { label: 'Why', value: whyText, html: (a) => `<span class="why">${why(a)}</span>`, wrap: true },
];
const machineColumns = [
  { label: 'Machine', value: (m) => short(m.name) },
  { label: 'Delivery group', value: (m) => m.deliveryGroup || '—' },
  { label: 'VDA version', value: (m) => m.agentVersion || '—' },
  { label: 'OS', value: (m) => m.osType || '' },
  { label: 'Registration', value: (m) => m.registrationState || '', html: (m) => (m.registrationState === 'Registered' ? 'Registered' : `<span class="state-warn">${e(m.registrationState)}</span>`) },
  { label: 'Maintenance', value: (m) => (m.inMaintenanceMode ? 'On' : 'Off') },
  { label: 'Assigned to', value: (m) => m.assignedTo.map(short).join(', ') },
  { label: 'Last connection', value: (m) => shortDate(m.lastConnectionTime) },
];

function problemList(container, items) {
  grid(container, {
    key: 'details-problems',
    columns: NODES.problems.columns,
    rows: items.map((item) => ({ ...item, index: String(state.report.recommendations.indexOf(item) + 1) })),
    rowKey: (p) => p.index,
    onSelect: (index) => { location.hash = `#/problems/${index}`; },
    empty: 'No problems.',
  });
}

function renderCatalog(catalog, tab, body) {
  const machines = state.report.machines.filter((machine) => machine.catalog === catalog.name);
  const users = new Set(catalog.access.filter((a) => a.status === 'Granted').map((a) => a.user));
  if (tab === 'Details') {
    body.innerHTML = props([
      ['Machine type', e(`${catalog.provisioningType} · ${catalog.sessionSupport === 'MultiSession' ? 'Multi-session OS' : 'Single-session OS'}`)],
      ['Allocation', e(catalog.allocationType)],
      ['User data', e(catalog.persistUserChanges === 'Discard' ? 'Discard (pooled)' : 'On local disk (persistent)')],
      ['Machines', e(`${catalog.machineCount} (${machines.filter((m) => m.registrationState === 'Registered').length} registered)`)],
      ['VDA versions', catalog.vdaVersions.map((v) => `${e(v.version || 'unknown')} × ${v.machines}`).join('<br>') || '—'],
      ['Delivery groups', catalog.deliveryGroups.map((name) => link('groups', name)).join(', ') || '<span class="state-warn">None</span>'],
      ['Users with access', e(users.size)],
      ['Software inventory', e(catalog.inventoriedMachines ? `${catalog.software.length} applications from ${plural(catalog.inventoriedMachines, 'machine')}` : 'Not collected')],
    ]);
  } else if (tab === 'Machines') {
    detailTable(body, { key: 'catalog-machines', columns: machineColumns, rows: machines, csvName: `${catalog.name}-machines.csv`, empty: 'No machines.' });
  } else if (tab === 'Users') {
    detailTable(body, { key: 'catalog-users', columns: accessColumns(false), rows: catalog.access, csvName: `${catalog.name}-users.csv`, empty: 'No user can reach this catalog.' });
  } else if (tab === 'Software') {
    detailTable(body, {
      key: 'catalog-software',
      columns: [
        { label: 'Application', value: (s) => s.name },
        { label: 'Publisher', value: (s) => s.publisher || '' },
        { label: 'Version', value: (s) => s.versions.map((v) => v.version).join(', '), html: (s) => (s.versions.length > 1 ? `<span class="state-warn">${e(s.versions.map((v) => `${v.version} (${v.machines})`).join(', '))}</span>` : e(s.versions[0]?.version || '')) },
        { label: 'Machines', value: (s) => s.versions.reduce((sum, v) => sum + v.machines, 0), num: true },
      ],
      rows: catalog.software,
      csvName: `${catalog.name}-software.csv`,
      empty: 'No software inventory for this catalog.',
    });
  } else {
    problemList(body, findingsFor(catalog.name));
  }
}

function renderGroup(group, tab, body) {
  const machines = state.report.machines.filter((machine) => machine.deliveryGroup === group.name);
  if (tab === 'Details') {
    body.innerHTML = props([
      ['Delivering', e(group.desktopKind === 'Private' ? 'Assigned (static) desktops' : 'Random (pooled) desktops')],
      ['State', group.enabled ? 'Enabled' : '<span class="state-warn">Disabled</span>'],
      ['Machine catalogs', group.catalogs.map((name) => link('catalogs', name)).join(', ') || '—'],
      ['Machines', e(group.machineCount)],
      ['Users allowed', e(group.grantedUsers)],
      ['Desktop rules', e(group.desktopRules.map((r) => r.name).join(', ') || 'None')],
      ['Access policy rules', e(group.accessRules.map((r) => r.name).join(', ') || 'None')],
    ]);
  } else if (tab === 'Users') {
    detailTable(body, { key: 'group-users', columns: accessColumns(false), rows: groupAccess(group.name), csvName: `${group.name}-users.csv`, empty: 'No users.' });
  } else if (tab === 'Access policy') {
    const rules = [
      ...group.desktopRules.map((r) => ({ ...r, type: r.kind === 'Assignment' ? 'Assignment rule' : 'Entitlement rule' })),
      ...group.accessRules.map((r) => ({ ...r, type: 'Access policy rule' })),
    ];
    detailTable(body, {
      key: 'group-rules',
      columns: [
        { label: 'Rule', value: (r) => r.name },
        { label: 'Type', value: (r) => r.type },
        { label: 'State', value: (r) => (r.enabled ? 'Enabled' : 'Disabled') },
        { label: 'Includes', value: (r) => r.includedUsers.map(short).join(', '), wrap: true },
        { label: 'Excludes', value: (r) => r.excludedUsers.map(short).join(', ') || '—', wrap: true },
      ],
      rows: rules,
      csvName: `${group.name}-rules.csv`,
      empty: 'No rules.',
    });
  } else {
    detailTable(body, { key: 'group-machines', columns: machineColumns, rows: machines, csvName: `${group.name}-machines.csv`, empty: 'No machines.' });
  }
}

function renderUser(user, tab, body) {
  if (tab === 'Access') {
    detailTable(body, { key: 'user-access', columns: accessColumns(true), rows: userEntries(user.name), csvName: `${short(user.name)}-access.csv`, empty: 'This user reaches no desktop.' });
  } else {
    problemList(body, userFindings(user.name));
  }
}

function renderProblem(problem, tab, body) {
  const keys = [...new Set(problem.evidence.flatMap((row) => Object.keys(row)))];
  const order = ['user', 'machine', 'kind', 'name', 'catalog', 'application', 'difference', 'found', 'expected', 'version', 'machines', 'deliveryGroup', 'desktopRule', 'rule', 'agentVersion', 'assignedTo', 'lastConnection', 'daysIdle', 'groupPath', 'users', 'levels', 'path', 'cycle', 'pattern', 'newest'];
  keys.sort((a, b) => (order.indexOf(a) + 1 || 99) - (order.indexOf(b) + 1 || 99));
  body.innerHTML = `<p class="action"><b>Recommended action.</b> ${e(problem.action)}</p><div></div>`;
  if (!problem.evidence.length) return;
  detailTable(body.lastElementChild, {
    key: `problem-${problem.id}`,
    columns: keys.map((key) => ({
      label: key.replace(/([A-Z])/g, ' $1').replace(/^./, (c) => c.toUpperCase()),
      value: (row) => (row[key] === true ? 'Yes' : row[key] === false ? 'No' : row[key] ?? ''),
      html: key === 'user' ? (row) => link('users', row.user) : undefined,
      wrap: /path|cycle|groupPath/.test(key),
      num: /^(machines|users|levels|daysIdle)$/.test(key),
    })),
    rows: problem.evidence,
    csvName: `${problem.id}-evidence.csv`,
  });
}

function renderCompare(names) {
  const result = compareCatalogs(state.report, names);
  $('list-title').textContent = `Compare ${plural(result.catalogs.length, 'catalog')}`;
  $('list-actions').innerHTML = '<a class="button" href="#/catalogs">Back to catalogs</a>';
  $('list-filter').parentElement.hidden = true;
  grid($('list'), { key: 'compare-list', columns: NODES.catalogs.columns, rows: result.catalogs.map((name) => catalogByName(state.report, name)) });
  const tab = routeTab() || 'Users';
  renderTabs(['Users', 'Software'], tab, (next) => { location.hash = `#/compare/${names.map(encodeURIComponent).join('|')}/${next}`; });
  $('details-title').innerHTML = e(tab === 'Users' ? `${result.sharedByAll} users reach all selected catalogs` : `${result.software.filter((s) => s.differs).length} applications differ in version`);
  const body = $('details');
  if (tab === 'Users') {
    detailTable(body, {
      key: 'compare-users',
      columns: [
        { label: 'User', value: (u) => u.user, html: (u) => link('users', u.user) },
        { label: 'Name', value: (u) => u.displayName || '' },
        ...result.catalogs.map((name) => ({ label: name, value: (u) => (u.catalogs[name] ? 'Yes' : ''), html: (u) => (u.catalogs[name] ? '<span class="state-ok">✓</span>' : '') })),
        { label: 'Catalogs', value: (u) => u.count, num: true },
      ],
      rows: result.users,
      csvName: 'compare-users.csv',
    });
  } else {
    detailTable(body, {
      key: 'compare-software',
      columns: [
        { label: 'Application', value: (s) => s.name },
        ...result.inventoried.map((name) => ({
          label: name,
          value: (s) => (s.catalogs[name] ? s.catalogs[name].join(', ') : '—'),
          html: (s) => (s.catalogs[name] ? (s.differs ? `<span class="state-warn">${e(s.catalogs[name].join(', '))}</span>` : e(s.catalogs[name].join(', '))) : '<span class="dim">—</span>'),
        })),
      ],
      rows: result.software,
      csvName: 'compare-software.csv',
    });
  }
}

// ------------------------------------------------------------------ layout

function parseRoute() {
  const parts = location.hash.replace(/^#\/?/, '').split('/').map((part) => decodeURIComponent(part));
  const node = parts[0] in NODES || parts[0] === 'compare' ? parts[0] : 'catalogs';
  return { node, item: parts[1] || null, tab: parts[2] || null };
}
const routeTab = () => parseRoute().tab;

function renderTree(route) {
  const { report } = state;
  $('tree-site').innerHTML = `${e(report.site.name)}<small>Collected ${e(shortDate(report.site.collectedAt))} UTC</small>`;
  const counts = {
    catalogs: report.catalogs.length,
    groups: report.deliveryGroups.length,
    users: report.users.length,
    problems: report.recommendations.length,
  };
  $('tree').innerHTML = Object.entries(NODES).map(([key, node]) => {
    const current = route.node === key || (route.node === 'compare' && key === 'catalogs');
    const badge = key === 'problems'
      ? `<span class="alert" title="High severity">${report.recommendations.filter((r) => r.severity === 'High').length || ''}</span>`
      : `<span class="count">${counts[key]}</span>`;
    return `<li><a href="#/${key}" aria-current="${current ? 'page' : 'false'}"><span class="icon" aria-hidden="true">${node.icon}</span>${e(node.label)}${key === 'problems' ? `<span class="count">${counts[key]}</span>` : ''}${badge}</a></li>`;
  }).join('');
}

function renderTabs(tabs, active, onPick) {
  $('details-tabs').innerHTML = tabs.map((tab) => `<button type="button" role="tab" aria-selected="${tab === active}" data-tab="${e(tab)}">${e(tab)}</button>`).join('');
  for (const button of $('details-tabs').querySelectorAll('button')) button.addEventListener('click', () => onPick(button.dataset.tab));
}

function renderListActions() {
  const route = parseRoute();
  if (route.node !== 'catalogs') {
    $('list-actions').innerHTML = '';
    return;
  }
  $('list-actions').innerHTML = `<button type="button" id="compare" ${state.checked.size < 2 ? 'disabled' : ''}>Compare selected (${state.checked.size})</button>`;
  $('compare').addEventListener('click', () => { location.hash = `#/compare/${[...state.checked].map(encodeURIComponent).join('|')}`; });
}

function render() {
  if (!state.report) return;
  const route = parseRoute();
  renderTree(route);
  $('list-filter').parentElement.hidden = false;
  if (route.node === 'compare') {
    renderCompare((route.item || '').split('|').filter(Boolean));
    return;
  }
  const node = NODES[route.node];
  const items = node.items();
  const selectedItem = items.find((item) => node.key(item) === route.item) || items[0];
  const selectedKey = selectedItem ? node.key(selectedItem) : null;
  $('list-title').textContent = node.label;
  renderListActions();

  const drawList = () => {
    const visible = filterRows(items.map((item) => ({ item, text: node.columns.map((column) => column.value(item)).join(' ') })), state.listFilter, ['text']).map((row) => row.item);
    $('list-count').textContent = `${visible.length} of ${items.length}`;
    grid($('list'), {
      key: `list-${route.node}`,
      columns: node.columns,
      rows: visible,
      selected: selectedKey,
      rowKey: node.key,
      checkable: node.checkable,
      onSelect: (key) => { location.hash = `#/${route.node}/${encodeURIComponent(key)}`; },
      empty: 'No items match the filter.',
    });
  };
  $('list-filter').value = state.listFilter;
  $('list-filter').oninput = () => { state.listFilter = $('list-filter').value; drawList(); };
  drawList();

  if (!selectedItem) {
    $('details-title').textContent = '';
    $('details-tabs').innerHTML = '';
    $('details').innerHTML = '<p class="empty">Nothing selected.</p>';
    return;
  }
  const tab = node.tabs.includes(route.tab) ? route.tab : node.tabs[0];
  $('details-title').innerHTML = node === NODES.users ? node.title(selectedItem) : e(node.title(selectedItem));
  renderTabs(node.tabs, tab, (next) => { location.hash = `#/${route.node}/${encodeURIComponent(selectedKey)}/${encodeURIComponent(next)}`; });
  $('details').innerHTML = '';
  node.render(selectedItem, tab, $('details'));
}

function load(report, label, { resetRoute = true } = {}) {
  try {
    state.report = validateReport(report);
  } catch (error) {
    notice(`${label}: ${error.message}`);
    return;
  }
  notice('');
  state.checked.clear();
  state.sort = {};
  state.listFilter = '';
  const site = report.site;
  $('site-line').innerHTML = `${site.source === 'synthetic' ? '<span class="tag">fictional demo site</span>' : ''}${site.pseudonymized ? '<span class="tag">pseudonymized</span>' : ''}`;
  if (resetRoute && location.hash && location.hash !== '#/catalogs') location.hash = '#/catalogs';
  else render();
}

async function loadDemo({ resetRoute = true } = {}) {
  try {
    const response = await fetch('data/demo-report.json');
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    load(await response.json(), 'Demo', { resetRoute });
  } catch (error) {
    notice(`Could not load the demo report (${error.message}). Serve the page with scripts/Start-ReviewPage.ps1, or open a report.json.`);
  }
}

$('open-file').addEventListener('change', async (event) => {
  const [file] = event.target.files;
  event.target.value = '';
  if (!file) return;
  try {
    load(JSON.parse(await file.text()), file.name);
  } catch (error) {
    notice(`${file.name}: ${error.message}`);
  }
});
$('load-demo').addEventListener('click', () => loadDemo());
$('user-search').addEventListener('keydown', (event) => {
  if (event.key !== 'Enter') return;
  const [match] = lookupUsers(state.report, event.target.value);
  if (match) location.hash = `#/users/${encodeURIComponent(match.name)}`;
  else notice(`No user matches "${event.target.value}".`);
});
$('user-search').addEventListener('input', (event) => {
  if (!state.report) return;
  notice('');
  if (parseRoute().node !== 'users') return;
  state.listFilter = event.target.value;
  render();
});
window.addEventListener('hashchange', () => {
  const route = parseRoute();
  if (route.node !== parseRoute.lastNode) state.listFilter = '';
  parseRoute.lastNode = route.node;
  render();
});

// The first load keeps the address, so links to a catalog or a user work.
loadDemo({ resetRoute: false });
