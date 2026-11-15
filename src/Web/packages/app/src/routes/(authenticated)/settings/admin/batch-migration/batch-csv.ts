/**
 * Reads the user list a platform administrator pastes into the batch migration page.
 *
 * One user per line, comma separated, with a header row naming the columns. Recognised columns
 * (any order, case-insensitive): slug, displayName, ownerUsername, ownerEmail, mongoDatabaseName,
 * mongoConnectionString. Only slug and mongoDatabaseName are required; displayName falls back to
 * the slug and ownerUsername to the slug on the server.
 */
import type { BatchMigrationUserRequest } from "#lib/api/index.js";

export const BATCH_CSV_COLUMNS = [
  "slug",
  "displayName",
  "ownerUsername",
  "ownerEmail",
  "mongoDatabaseName",
  "mongoConnectionString",
] as const;

type Column = (typeof BATCH_CSV_COLUMNS)[number];

export const BATCH_CSV_TEMPLATE =
  "slug,displayName,ownerUsername,ownerEmail,mongoDatabaseName,mongoConnectionString\n" +
  "jane,Jane Doe,jane,jane@example.com,nightscout_jane,\n";

export interface BatchCsvResult {
  users: BatchMigrationUserRequest[];
  /** Problems with the text itself, by 1-based line number (0 for the header). */
  errors: { line: number; message: string }[];
}

const ALIASES: Record<string, Column> = {
  slug: "slug",
  subdomain: "slug",
  displayname: "displayName",
  name: "displayName",
  ownerusername: "ownerUsername",
  username: "ownerUsername",
  owneremail: "ownerEmail",
  email: "ownerEmail",
  mongodatabasename: "mongoDatabaseName",
  database: "mongoDatabaseName",
  databasename: "mongoDatabaseName",
  db: "mongoDatabaseName",
  mongoconnectionstring: "mongoConnectionString",
  connectionstring: "mongoConnectionString",
  mongouri: "mongoConnectionString",
  uri: "mongoConnectionString",
};

/** Splits one CSV line, honouring double-quoted fields (a connection string may hold commas). */
export function splitCsvLine(line: string): string[] {
  const fields: string[] = [];
  let current = "";
  let quoted = false;

  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"' && line[i + 1] === '"') {
        current += '"';
        i++;
      } else if (ch === '"') {
        quoted = false;
      } else {
        current += ch;
      }
    } else if (ch === '"') {
      quoted = true;
    } else if (ch === ",") {
      fields.push(current);
      current = "";
    } else {
      current += ch;
    }
  }

  fields.push(current);
  return fields.map((f) => f.trim());
}

export function parseBatchCsv(text: string): BatchCsvResult {
  const lines = text
    .split(/\r?\n/)
    .map((line, i) => ({ line: i + 1, text: line }))
    .filter((l) => l.text.trim() !== "" && !l.text.trim().startsWith("#"));

  if (lines.length === 0) return { users: [], errors: [] };

  const header = splitCsvLine(lines[0].text).map((h) => ALIASES[h.replace(/[\s_-]/g, "").toLowerCase()]);
  const errors: BatchCsvResult["errors"] = [];

  if (!header.includes("slug"))
    errors.push({ line: 0, message: "The header row needs a slug column." });
  if (!header.includes("mongoDatabaseName"))
    errors.push({ line: 0, message: "The header row needs a mongoDatabaseName column." });
  if (errors.length > 0) return { users: [], errors };

  const users: BatchMigrationUserRequest[] = [];
  for (const { line, text: raw } of lines.slice(1)) {
    const fields = splitCsvLine(raw);
    const row: Partial<Record<Column, string>> = {};
    header.forEach((column, i) => {
      if (column && fields[i]) row[column] = fields[i];
    });

    if (!row.slug) {
      errors.push({ line, message: "Missing slug." });
      continue;
    }

    users.push({
      slug: row.slug.toLowerCase(),
      displayName: row.displayName ?? row.slug,
      ownerUsername: row.ownerUsername || undefined,
      ownerEmail: row.ownerEmail || undefined,
      mongoDatabaseName: row.mongoDatabaseName ?? "",
      mongoConnectionString: row.mongoConnectionString || undefined,
    });
  }

  return { users, errors };
}

/** Builds a CSV of claim links for the administrator to send to each user. */
export function claimLinksCsv(
  links: { slug?: string; ownerUsername?: string; url?: string | null; expiresAt?: Date | string | null; errorMessage?: string | null }[],
): string {
  const escape = (value: unknown) => {
    const s = value == null ? "" : value instanceof Date ? value.toISOString() : String(value);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const rows = links.map((l) =>
    [l.slug, l.ownerUsername, l.url, l.expiresAt, l.errorMessage].map(escape).join(","),
  );
  return ["slug,ownerUsername,claimUrl,expiresAt,note", ...rows].join("\n") + "\n";
}
