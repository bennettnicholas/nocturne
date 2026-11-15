import { describe, expect, it } from "vitest";
import { claimLinksCsv, parseBatchCsv, splitCsvLine } from "./batch-csv";

describe("splitCsvLine", () => {
  it("keeps commas inside quoted fields", () => {
    expect(splitCsvLine('a,"mongodb://h1,h2/?x=1",c')).toEqual(["a", "mongodb://h1,h2/?x=1", "c"]);
  });

  it("unescapes doubled quotes", () => {
    expect(splitCsvLine('"say ""hi""",b')).toEqual(['say "hi"', "b"]);
  });
});

describe("parseBatchCsv", () => {
  it("reads rows by header, in any order and with aliases", () => {
    const result = parseBatchCsv(
      "database,Slug,Name,email\nns_jane,Jane,Jane Doe,jane@example.com\nns_bob,bob,,\n",
    );
    expect(result.errors).toEqual([]);
    expect(result.users).toEqual([
      {
        slug: "jane",
        displayName: "Jane Doe",
        ownerUsername: undefined,
        ownerEmail: "jane@example.com",
        mongoDatabaseName: "ns_jane",
        mongoConnectionString: undefined,
      },
      {
        slug: "bob",
        displayName: "bob",
        ownerUsername: undefined,
        ownerEmail: undefined,
        mongoDatabaseName: "ns_bob",
        mongoConnectionString: undefined,
      },
    ]);
  });

  it("skips blank and comment lines", () => {
    const result = parseBatchCsv("slug,db\n\n# a note\njane,ns_jane\n");
    expect(result.users).toHaveLength(1);
  });

  it("refuses a header without the required columns", () => {
    const result = parseBatchCsv("name,email\nJane,jane@example.com\n");
    expect(result.users).toEqual([]);
    expect(result.errors.map((e) => e.line)).toEqual([0, 0]);
  });

  it("reports a row without a slug by line number", () => {
    const result = parseBatchCsv("slug,db\n,ns_x\njane,ns_jane\n");
    expect(result.errors).toEqual([{ line: 2, message: "Missing slug." }]);
    expect(result.users).toHaveLength(1);
  });
});

describe("claimLinksCsv", () => {
  it("quotes fields that need it", () => {
    const csv = claimLinksCsv([
      { slug: "jane", ownerUsername: "jane", url: "https://jane.example/auth/recovery?code=a,b", expiresAt: null },
    ]);
    expect(csv).toBe(
      'slug,ownerUsername,claimUrl,expiresAt,note\njane,jane,"https://jane.example/auth/recovery?code=a,b",,\n',
    );
  });
});
