// Pure helpers for the review page. The page never recomputes access or
// recommendations: those come from the PowerShell module in report.json. These
// functions only filter, compare, and export what the report already contains.

export const REPORT_KIND = 'citrix-catalog-baseline-report';
export const SCHEMA_VERSION = 1;
export const SEVERITIES = Object.freeze(['High', 'Medium', 'Low', 'Info']);

export class ReportError extends Error {}

export function validateReport(report) {
  if (!report || typeof report !== 'object' || Array.isArray(report)) {
    throw new ReportError('The file is not a JSON object.');
  }
  if (report.kind !== REPORT_KIND) {
    throw new ReportError('This is not a Citrix Catalog Baseline report. Create one with scripts/Invoke-CatalogReview.ps1; a snapshot file must be turned into a report first.');
  }
  if (report.schemaVersion !== SCHEMA_VERSION) {
    throw new ReportError(`Unsupported report schema version ${report.schemaVersion}; this page reads version ${SCHEMA_VERSION}.`);
  }
  for (const key of ['catalogs', 'deliveryGroups', 'machines', 'users', 'recommendations']) {
    if (!Array.isArray(report[key])) throw new ReportError(`The report has no "${key}" list.`);
  }
  return report;
}

const text = (value) => (value === null || value === undefined ? '' : Array.isArray(value) ? value.join(' ') : String(value));

// Case-insensitive match of every word in the query against the given fields.
export function filterRows(rows, query, keys) {
  const words = String(query || '').toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return rows;
  return rows.filter((row) => {
    const haystack = keys.map((key) => text(row[key])).join(' ').toLowerCase();
    return words.every((word) => haystack.includes(word));
  });
}

// RFC 4180 CSV. Cells that a spreadsheet would treat as a formula are prefixed
// with an apostrophe so an exported report cannot run code when opened.
export function toCsv(columns, rows) {
  const cell = (value) => {
    let result = text(value);
    if (/^[=+\-@\t\r]/.test(result)) result = `'${result}`;
    return /[",\r\n]/.test(result) ? `"${result.replace(/"/g, '""')}"` : result;
  };
  const lines = [columns.map((column) => cell(column.label)).join(',')];
  for (const row of rows) {
    lines.push(columns.map((column) => cell(column.value ? column.value(row) : row[column.key])).join(','));
  }
  return `${lines.join('\r\n')}\r\n`;
}

export function catalogByName(report, name) {
  return report.catalogs.find((catalog) => catalog.name === name) || null;
}

export function recommendationsFor(report, catalogName = null) {
  if (!catalogName) return report.recommendations;
  return report.recommendations.filter((item) => item.catalogs.includes(catalogName));
}

export function severityCounts(recommendations) {
  const counts = Object.fromEntries(SEVERITIES.map((severity) => [severity, 0]));
  for (const item of recommendations) counts[item.severity] = (counts[item.severity] || 0) + 1;
  return counts;
}

// Users and software side by side for two or more catalogs.
export function compareCatalogs(report, names) {
  const catalogs = names.map((name) => catalogByName(report, name)).filter(Boolean);
  const users = new Map();
  for (const catalog of catalogs) {
    for (const entry of catalog.access) {
      if (entry.status !== 'Granted') continue;
      if (!users.has(entry.user)) {
        users.set(entry.user, { user: entry.user, displayName: entry.displayName, enabled: entry.enabled, catalogs: {} });
      }
      const row = users.get(entry.user);
      (row.catalogs[catalog.name] ||= []).push(entry.deliveryGroup);
    }
  }
  const userRows = [...users.values()]
    .map((row) => ({ ...row, count: Object.keys(row.catalogs).length }))
    .sort((a, b) => b.count - a.count || a.user.localeCompare(b.user));

  const software = new Map();
  for (const catalog of catalogs) {
    for (const app of catalog.software) {
      if (!software.has(app.name)) software.set(app.name, { name: app.name, publisher: app.publisher, catalogs: {} });
      software.get(app.name).catalogs[catalog.name] = app.versions.map((item) => item.version);
    }
  }
  const inventoried = catalogs.filter((catalog) => catalog.inventoriedMachines > 0).map((catalog) => catalog.name);
  const softwareRows = [...software.values()].map((row) => {
    const present = inventoried.filter((name) => row.catalogs[name]);
    const versions = new Set(present.flatMap((name) => row.catalogs[name]));
    return {
      ...row,
      missing: inventoried.length > 0 && present.length < inventoried.length,
      differs: versions.size > 1,
    };
  }).sort((a, b) => Number(b.differs) - Number(a.differs) || Number(b.missing) - Number(a.missing) || a.name.localeCompare(b.name));

  return {
    catalogs: catalogs.map((catalog) => catalog.name),
    inventoried,
    users: userRows,
    sharedByAll: userRows.filter((row) => row.count === catalogs.length).length,
    software: softwareRows,
  };
}

// Every access entry for the users whose name or display name matches.
export function lookupUsers(report, query, limit = 25) {
  const words = String(query || '').toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  const matches = report.users.filter((user) => {
    const haystack = `${user.name} ${user.displayName || ''}`.toLowerCase();
    return words.every((word) => haystack.includes(word));
  }).slice(0, limit);
  return matches.map((user) => ({
    ...user,
    entries: report.catalogs.flatMap((catalog) => catalog.access
      .filter((entry) => entry.user === user.name)
      .map((entry) => ({ catalog: catalog.name, ...entry }))),
  }));
}
