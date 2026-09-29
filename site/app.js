import {
  SEVERITIES,
  catalogByName,
  compareCatalogs,
  filterRows,
  lookupUsers,
  recommendationsFor,
  severityCounts,
  toCsv,
  validateReport,
} from './lib/review.js';

const $ = (id) => document.getElementById(id);
const state = { report: null, compare: new Set(), filters: {} };

// Everything in the report came from a file the user opened: escape it all.
const e = (value) => String(value ?? '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const plural = (count, word) => `${count} ${word}${count === 1 ? '' : 's'}`;
const shortDate = (iso) => (iso ? iso.replace('T', ' ').replace(/:\d\dZ$/, ' UTC') : '');

function notice(message) {
  $('notice').textContent = message || '';
  $('notice').hidden = !message;
}

function download(name, content, type = 'text/csv') {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}

// ------------------------------------------------------------------ tables

// A filterable table with a row count and CSV export. Columns declare a label,
// a plain value (for filtering and CSV), and optionally escaped HTML.
function table(container, { id, columns, rows, placeholder = 'filter…', csvName, extra = '', rowClass }) {
  const filterKey = `${location.hash}|${id}`;
  container.insertAdjacentHTML('beforeend', `
    <div class="toolbar">
      <input type="search" placeholder="${e(placeholder)}" value="${e(state.filters[filterKey] || '')}" aria-label="Filter rows">
      ${extra}
      <span class="shown"></span>
      <span class="grow"></span>
      <button type="button" data-csv>CSV</button>
    </div>
    <div class="table-wrap"><table class="grid"><thead><tr>${columns.map((column) =>
      `<th class="${column.num ? 'num' : ''}">${e(column.label)}</th>`).join('')}</tr></thead><tbody></tbody></table></div>`);
  const toolbar = container.lastElementChild.previousElementSibling;
  const input = toolbar.querySelector('input');
  const body = container.lastElementChild.querySelector('tbody');
  const plain = (column, row) => (column.value ? column.value(row) : row[column.key]);
  const render = () => {
    const visible = filterRows(rows.map((row) => ({ row, ...Object.fromEntries(columns.map((column, index) => [index, plain(column, row)])) })),
      input.value, columns.map((column, index) => index)).map((item) => item.row);
    body.innerHTML = visible.map((row) => `<tr class="${rowClass ? e(rowClass(row)) : ''}">${columns.map((column) =>
      `<td class="${column.className || ''}">${column.html ? column.html(row) : e(plain(column, row))}</td>`).join('')}</tr>`).join('')
      || `<tr><td colspan="${columns.length}" class="dim">No rows.</td></tr>`;
    toolbar.querySelector('.shown').textContent = `${visible.length} of ${rows.length}`;
    return visible;
  };
  input.addEventListener('input', () => {
    state.filters[filterKey] = input.value;
    render();
  });
  toolbar.querySelector('[data-csv]').addEventListener('click', () => {
    download(csvName, toCsv(columns.map((column) => ({ label: column.label, value: (row) => plain(column, row) })), render()));
  });
  render();
  return toolbar;
}

const pathHtml = (path) => {
  const parts = path || [];
  return parts.map((part, index) => (index === parts.length - 1 && index > 0 ? `<b>${e(part)}</b>` : e(part))).join(' › ');
};
const statusHtml = (status) => `<span class="status ${e(status)}">${e(status === 'BlockedByAccessPolicy' ? 'blocked by access policy' : status === 'DeliveryGroupDisabled' ? 'delivery group disabled' : 'granted')}</span>`;
const userHtml = (row) => `<a href="#/user/${encodeURIComponent(row.user || row.name)}">${e(row.user || row.name)}</a>${row.enabled === false ? ' <span class="off">disabled</span>' : ''}`;

// ------------------------------------------------------------------ rail

function renderRail(route) {
  const { report } = state;
  if (route.view === 'compare') state.compare = new Set(route.names.filter((name) => catalogByName(report, name)));
  const counts = severityCounts(report.recommendations);
  $('nav-findings-counts').innerHTML = SEVERITIES.filter((severity) => counts[severity])
    .map((severity) => `<span class="sev ${severity}" title="${severity}">${counts[severity]}</span>`).join('');
  $('nav-findings').setAttribute('aria-current', route.view === 'findings' ? 'page' : 'false');

  $('catalog-list').innerHTML = report.catalogs.map((catalog) => {
    const findings = recommendationsFor(report, catalog.name);
    const high = findings.filter((item) => item.severity === 'High').length;
    const granted = new Set(catalog.access.filter((entry) => entry.status === 'Granted').map((entry) => entry.user)).size;
    const kind = `${catalog.provisioningType} · ${catalog.persistent ? 'persistent' : 'pooled'}${catalog.sessionSupport === 'MultiSession' ? ' · multi-session' : ''}`;
    const current = route.view === 'catalog' && route.name === catalog.name;
    return `<li>
      <input type="checkbox" data-compare="${e(catalog.name)}" ${state.compare.has(catalog.name) ? 'checked' : ''} aria-label="Compare ${e(catalog.name)}">
      <a href="#/catalog/${encodeURIComponent(catalog.name)}" aria-current="${current ? 'page' : 'false'}">
        <span class="cname"><span>${e(catalog.name)}</span>${high ? `<span class="sev High" title="High findings">${high}</span>` : ''}</span>
        <span class="cmeta">${e(kind)} · ${plural(catalog.machineCount, 'machine')} · ${plural(granted, 'user')}</span>
      </a>
    </li>`;
  }).join('');
  for (const box of document.querySelectorAll('[data-compare]')) {
    box.addEventListener('change', () => {
      if (box.checked) state.compare.add(box.dataset.compare);
      else state.compare.delete(box.dataset.compare);
      $('compare-button').disabled = state.compare.size < 2;
    });
  }
  $('compare-button').disabled = state.compare.size < 2;
}

// ------------------------------------------------------------------ views

function findingsList(container, recommendations, idPrefix) {
  if (!recommendations.length) {
    container.insertAdjacentHTML('beforeend', '<p class="empty">No findings.</p>');
    return;
  }
  const list = document.createElement('ul');
  list.className = 'findings';
  recommendations.forEach((item, index) => {
    const li = document.createElement('li');
    const bodyId = `${idPrefix}-${index}`;
    li.innerHTML = `
      <button type="button" class="finding-head" aria-expanded="false" aria-controls="${bodyId}">
        <span><span class="sev ${e(item.severity)}">${e(item.severity)}</span></span>
        <span class="id">${e(item.id)}</span>
        <span>${e(item.title)}</span>
        <span class="where">${e(item.catalogs.join(', '))}</span>
      </button>
      <div class="finding-body" id="${bodyId}" hidden><p class="action">${e(item.action)}</p></div>`;
    const head = li.querySelector('.finding-head');
    const body = li.querySelector('.finding-body');
    head.addEventListener('click', () => {
      const open = head.getAttribute('aria-expanded') === 'true';
      head.setAttribute('aria-expanded', String(!open));
      body.hidden = open;
      if (!open && !body.dataset.filled && item.evidence.length) {
        body.dataset.filled = '1';
        const keys = [...new Set(item.evidence.flatMap((row) => Object.keys(row)))];
        const order = ['user', 'machine', 'catalog', 'application', 'difference', 'found', 'expected', 'version', 'machines', 'deliveryGroup', 'desktopRule', 'rule', 'agentVersion', 'assignedTo', 'lastConnection', 'daysIdle', 'groupPath', 'users', 'levels', 'path', 'cycle', 'newest'];
        keys.sort((a, b) => (order.indexOf(a) + 1 || 99) - (order.indexOf(b) + 1 || 99));
        table(body, {
          id: `${item.id}-${index}`,
          csvName: `${item.id}-evidence.csv`,
          columns: keys.map((key) => ({
            label: key.replace(/([A-Z])/g, ' $1').toLowerCase(),
            key,
            className: /path|cycle|groupPath/.test(key) ? 'path' : /version|found|expected|agentVersion|machine$|lastConnection/.test(key) ? 'mono' : /machines|users|levels|daysIdle/.test(key) ? 'num' : '',
            html: key === 'user' ? (row) => userHtml({ user: row.user }) : undefined,
          })),
          rows: item.evidence,
        });
      }
    });
    list.appendChild(li);
  });
  container.appendChild(list);
}

function viewFindings(main) {
  const { report } = state;
  const counts = severityCounts(report.recommendations);
  main.innerHTML = `
    <h1>Findings</h1>
    <p class="summary-line"><b>${report.summary.catalogs}</b> catalogs · <b>${report.summary.deliveryGroups}</b> delivery groups ·
      <b>${report.summary.machines}</b> machines · <b>${report.summary.usersWithAccess}</b> users with access ·
      ${SEVERITIES.map((severity) => `<span class="sev ${severity}">${counts[severity]}</span> ${severity.toLowerCase()}`).join(' · ')}</p>
    <div class="toolbar"><label>severity <select id="severity-filter"><option value="">all</option>${SEVERITIES.map((severity) =>
      `<option>${severity}</option>`).join('')}</select></label><span class="shown" id="findings-shown"></span></div>
    <div id="findings-list"></div>`;
  const select = $('severity-filter');
  select.value = state.filters.severity || '';
  const render = () => {
    state.filters.severity = select.value;
    const items = report.recommendations.filter((item) => !select.value || item.severity === select.value);
    $('findings-list').innerHTML = '';
    $('findings-shown').textContent = `${items.length} of ${report.recommendations.length}`;
    findingsList($('findings-list'), items, 'finding');
  };
  select.addEventListener('change', render);
  render();
}

function viewCatalog(main, name, tab = 'access') {
  const { report } = state;
  const catalog = catalogByName(report, name);
  if (!catalog) {
    main.innerHTML = `<p class="empty">No catalog named ${e(name)} in this report.</p>`;
    return;
  }
  const machines = report.machines.filter((machine) => machine.catalog === catalog.name);
  const findings = recommendationsFor(report, catalog.name);
  const tabs = [
    ['access', 'Access', catalog.access.length],
    ['software', 'Software', catalog.software.length],
    ['machines', 'Machines', machines.length],
    ['findings', 'Findings', findings.length],
  ];
  const vda = catalog.vdaVersions.map((item) => `${e(item.version || 'unknown')} ×${item.machines}`).join(', ') || 'none';
  main.innerHTML = `
    <h1>${e(catalog.name)}</h1>
    <p class="facts"><b>${e(catalog.provisioningType)}</b> · ${e(catalog.allocationType)} · changes ${e(catalog.persistUserChanges)} · ${e(catalog.sessionSupport)} ·
      ${catalog.persistent ? '<b>persistent</b>' : 'pooled'} · delivery groups: ${catalog.deliveryGroups.length ? e(catalog.deliveryGroups.join(', ')) : '<b>none</b>'} ·
      VDA ${vda} · software from ${plural(catalog.inventoriedMachines, 'machine')}</p>
    <div class="tabs" role="tablist">${tabs.map(([key, label, count]) =>
      `<button type="button" role="tab" aria-selected="${key === tab}" data-tab="${key}">${label}<span class="n">${count}</span></button>`).join('')}</div>
    <div id="tab-body"></div>`;
  for (const button of main.querySelectorAll('[data-tab]')) {
    button.addEventListener('click', () => { location.hash = `#/catalog/${encodeURIComponent(catalog.name)}/${button.dataset.tab}`; });
  }
  const body = $('tab-body');
  const slug = catalog.name.replace(/[^\w.-]+/g, '_');
  if (tab === 'access') {
    table(body, {
      id: 'access',
      csvName: `${slug}-access.csv`,
      placeholder: 'filter users, groups, status…',
      columns: [
        { label: 'User', key: 'user', html: userHtml },
        { label: 'Name', key: 'displayName' },
        { label: 'Delivery group', key: 'deliveryGroup' },
        { label: 'Status', key: 'status', html: (row) => statusHtml(row.status) },
        { label: 'Granted by', value: (row) => `${row.grantedBy || ''}${row.desktopRule ? `: ${row.desktopRule}` : ''}`, html: (row) => `<span title="${e(row.grantedBy)}">${e(row.grantedBy === 'Machine assignment' ? 'machine assignment' : row.desktopRule)}</span>` },
        { label: 'Path', value: (row) => (row.path || []).join(' > '), html: (row) => pathHtml(row.path), className: 'path' },
        { label: 'Machine', key: 'machine', className: 'mono' },
      ],
      rows: catalog.access,
    });
  } else if (tab === 'software') {
    if (!catalog.inventoriedMachines) {
      body.innerHTML = '<p class="empty">No machine in this catalog was inventoried.</p>';
      return;
    }
    table(body, {
      id: 'software',
      csvName: `${slug}-software.csv`,
      columns: [
        { label: 'Application', key: 'name' },
        { label: 'Publisher', key: 'publisher' },
        { label: 'Version (machines)', value: (row) => row.versions.map((item) => `${item.version} (${item.machines})`).join(', '), className: 'mono' },
      ],
      rows: catalog.software,
      rowClass: (row) => (row.versions.length > 1 ? 'diff' : ''),
    });
  } else if (tab === 'machines') {
    table(body, {
      id: 'machines',
      csvName: `${slug}-machines.csv`,
      columns: [
        { label: 'Machine', key: 'name', className: 'mono' },
        { label: 'Delivery group', value: (row) => row.deliveryGroup || '—' },
        { label: 'VDA', key: 'agentVersion', className: 'mono' },
        { label: 'OS', key: 'osType' },
        { label: 'Registration', key: 'registrationState' },
        { label: 'Maintenance', value: (row) => (row.inMaintenanceMode ? 'on' : '') },
        { label: 'Assigned to', value: (row) => row.assignedTo.join(', ') },
        { label: 'Last connection', value: (row) => shortDate(row.lastConnectionTime), className: 'mono' },
        { label: 'Apps', value: (row) => (row.softwareCount ?? '—'), className: 'num', num: true },
      ],
      rows: machines,
    });
  } else {
    findingsList(body, findings, 'catalog-finding');
  }
}

function viewCompare(main, names) {
  const result = compareCatalogs(state.report, names);
  if (result.catalogs.length < 2) {
    main.innerHTML = '<p class="empty">Pick at least two catalogs to compare.</p>';
    return;
  }
  const multi = result.users.filter((row) => row.count > 1).length;
  const differing = result.software.filter((row) => row.differs).length;
  const missing = result.software.filter((row) => row.missing).length;
  main.innerHTML = `
    <h1>Compare ${plural(result.catalogs.length, 'catalog')}</h1>
    <p class="facts">${result.catalogs.map((name) => `<a href="#/catalog/${encodeURIComponent(name)}">${e(name)}</a>`).join(' · ')}</p>
    <section><h2>Users <span class="dim">· ${multi} reach more than one · ${result.sharedByAll} reach all</span></h2><div id="compare-users"></div></section>
    <section><h2>Software <span class="dim">· ${differing} run different versions · ${missing} missing from at least one catalog</span></h2><div id="compare-software"></div></section>`;
  viewCompareUsers(result, true);
  if (result.inventoried.length < 2) {
    $('compare-software').innerHTML = '<p class="empty">At least two of these catalogs need a software inventory.</p>';
    return;
  }
  table($('compare-software'), {
    id: 'compare-software',
    csvName: 'compare-software.csv',
    columns: [
      { label: 'Application', key: 'name' },
      ...result.inventoried.map((name) => ({
        label: name,
        value: (row) => (row.catalogs[name] ? row.catalogs[name].join(', ') : ''),
        html: (row) => (row.catalogs[name] ? e(row.catalogs[name].join(', ')) : '<span class="dim">—</span>'),
        className: 'mono',
      })),
    ],
    rows: result.software,
    rowClass: (row) => (row.differs ? 'diff' : ''),
  });
}

function viewCompareUsers(result, onlyShared) {
  const toolbar = table($('compare-users'), {
    id: `compare-users-${onlyShared}`,
    csvName: 'compare-users.csv',
    extra: `<label><input type="checkbox" id="only-shared" ${onlyShared ? 'checked' : ''}> only users in more than one</label>`,
    columns: [
      { label: 'User', key: 'user', html: userHtml },
      { label: 'Name', key: 'displayName' },
      ...result.catalogs.map((name) => ({
        label: name,
        value: (row) => (row.catalogs[name] ? row.catalogs[name].join(', ') : ''),
        html: (row) => (row.catalogs[name] ? `<span class="tick" title="${e(row.catalogs[name].join(', '))}">✓</span>` : ''),
        className: 'center',
      })),
      { label: 'Catalogs', key: 'count', className: 'num', num: true },
    ],
    rows: onlyShared ? result.users.filter((row) => row.count > 1) : result.users,
  });
  toolbar.querySelector('#only-shared').addEventListener('change', (event) => {
    $('compare-users').innerHTML = '';
    viewCompareUsers(result, event.target.checked);
  });
}

function viewUser(main, query) {
  const matches = lookupUsers(state.report, query);
  main.innerHTML = `<h1>Users matching “${e(query)}”</h1><p class="facts">${plural(matches.length, 'user')}${matches.length === 25 ? ' (first 25)' : ''}</p><div id="user-results"></div>`;
  if (!matches.length) {
    $('user-results').innerHTML = '<p class="empty">No user in this report matches. Users appear only when some rule grants them a desktop.</p>';
    return;
  }
  for (const user of matches) {
    const section = document.createElement('section');
    section.innerHTML = `<h2>${e(user.name)} <span class="dim">${e(user.displayName || '')}</span> ${user.enabled === false ? '<span class="off">disabled account</span>' : ''}</h2>
      <p class="facts">reaches ${user.catalogs.length ? e(user.catalogs.join(', ')) : 'no catalog'}${user.blocked.length ? ` · ${plural(user.blocked.length, 'blocked entry')}` : ''}</p>`;
    table(section, {
      id: `user-${user.name}`,
      csvName: `${user.name.replace(/[^\w.-]+/g, '_')}-access.csv`,
      columns: [
        { label: 'Catalog', key: 'catalog', html: (row) => `<a href="#/catalog/${encodeURIComponent(row.catalog)}">${e(row.catalog)}</a>` },
        { label: 'Delivery group', key: 'deliveryGroup' },
        { label: 'Status', key: 'status', html: (row) => statusHtml(row.status) },
        { label: 'Granted by', value: (row) => `${row.grantedBy || ''}${row.desktopRule ? `: ${row.desktopRule}` : ''}`, html: (row) => `<span title="${e(row.grantedBy)}">${e(row.grantedBy === 'Machine assignment' ? 'machine assignment' : row.desktopRule)}</span>` },
        { label: 'Path', value: (row) => (row.path || []).join(' > '), html: (row) => pathHtml(row.path), className: 'path' },
        { label: 'Machine', key: 'machine', className: 'mono' },
      ],
      rows: user.entries,
    });
    $('user-results').appendChild(section);
  }
}

// ------------------------------------------------------------------ routing

function parseRoute() {
  const parts = location.hash.replace(/^#\/?/, '').split('/').map((part) => decodeURIComponent(part));
  if (parts[0] === 'catalog' && parts[1]) return { view: 'catalog', name: parts[1], tab: parts[2] || 'access' };
  if (parts[0] === 'compare' && parts[1]) return { view: 'compare', names: parts[1].split('|') };
  if (parts[0] === 'user' && parts[1]) return { view: 'user', query: parts[1] };
  return { view: 'findings' };
}

function render() {
  if (!state.report) return;
  const route = parseRoute();
  renderRail(route);
  const main = $('main');
  if (route.view === 'catalog') viewCatalog(main, route.name, route.tab);
  else if (route.view === 'compare') viewCompare(main, route.names);
  else if (route.view === 'user') viewUser(main, route.query);
  else viewFindings(main);
}

function load(report, label, { resetRoute = true } = {}) {
  try {
    state.report = validateReport(report);
  } catch (error) {
    notice(`${label}: ${error.message}`);
    return;
  }
  notice('');
  state.compare.clear();
  state.filters = {};
  const site = report.site;
  $('site-line').innerHTML = `${e(site.name)} · collected ${e(shortDate(site.collectedAt))}${site.source === 'synthetic' ? '<span class="tag">fictional demo</span>' : ''}${site.pseudonymized ? '<span class="tag">pseudonymized</span>' : ''}`;
  if (resetRoute && location.hash && location.hash !== '#/') location.hash = '#/';
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
$('compare-button').addEventListener('click', () => {
  location.hash = `#/compare/${[...state.compare].map(encodeURIComponent).join('|')}`;
});
let searchTimer = null;
$('user-search').addEventListener('input', (event) => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    const query = event.target.value.trim();
    location.hash = query ? `#/user/${encodeURIComponent(query)}` : '#/';
  }, 250);
});
window.addEventListener('hashchange', () => {
  render();
  $('main').focus({ preventScroll: true });
});

// The first load keeps the address, so links to a catalog or a user work.
loadDemo({ resetRoute: false });
