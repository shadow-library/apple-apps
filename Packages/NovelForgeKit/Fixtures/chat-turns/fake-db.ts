// An in-memory stand-in for the drizzle handle the reference services take: tables of rows, the predicate builders the services use, and the
// query, insert, update, delete and select chains they await. A transaction restores its tables when its body throws.

type Row = Record<string, unknown>;
export type Predicate = (row: Row) => boolean;

export interface Column {
  readonly table: string;
  readonly column: string;
}

interface SqlFragment {
  readonly strings: readonly string[];
  readonly values: readonly unknown[];
}

const COLUMN = Symbol('column');
const SQL = Symbol('sql');

export const schema: Record<string, Record<string, Column>> = new Proxy({} as Record<string, Record<string, Column>>, {
  get: (_, table) =>
    new Proxy({} as Record<string, Column>, {
      get: (__, column) => (column === 'enumValues' ? [] : { [COLUMN]: true, table: String(table), column: String(column) }),
    }),
});

const isColumn = (value: unknown): value is Column => typeof value === 'object' && value !== null && COLUMN in value;
const isSql = (value: unknown): value is SqlFragment => typeof value === 'object' && value !== null && SQL in value;

const same = (left: unknown, right: unknown): boolean => {
  if (typeof left === 'bigint' || typeof right === 'bigint') return left !== null && right !== null && left !== undefined && right !== undefined && BigInt(left as never) === BigInt(right as never);
  return left === right;
};

const field = (column: unknown): string => {
  if (!isColumn(column)) throw new Error(`fake-db: a predicate names no column: ${String(column)}`);
  return column.column;
};

export const drizzle = {
  eq: (column: unknown, value: unknown): Predicate => row => same(row[field(column)], value),
  ne: (column: unknown, value: unknown): Predicate => row => !same(row[field(column)], value),
  gt: (column: unknown, value: unknown): Predicate => row => (row[field(column)] as number) > (value as number),
  lt: (column: unknown, value: unknown): Predicate => row => (row[field(column)] as number) < (value as number),
  gte: (column: unknown, value: unknown): Predicate => row => (row[field(column)] as number) >= (value as number),
  lte: (column: unknown, value: unknown): Predicate => row => (row[field(column)] as number) <= (value as number),
  isNull: (column: unknown): Predicate => row => row[field(column)] === null || row[field(column)] === undefined,
  isNotNull: (column: unknown): Predicate => row => row[field(column)] !== null && row[field(column)] !== undefined,
  inArray: (column: unknown, values: readonly unknown[]): Predicate => row => values.some(value => same(row[field(column)], value)),
  notInArray: (column: unknown, values: readonly unknown[]): Predicate => row => !values.some(value => same(row[field(column)], value)),
  between: (column: unknown, low: unknown, high: unknown): Predicate => row => (row[field(column)] as number) >= (low as number) && (row[field(column)] as number) <= (high as number),
  like: (): Predicate => {
    throw new Error('fake-db: like is not evaluated');
  },
  notExists: (): Predicate => {
    throw new Error('fake-db: notExists is not evaluated');
  },
  getTableColumns: (table: unknown) => table,
  and: (...parts: (Predicate | undefined)[]): Predicate => row => parts.every(part => part === undefined || part(row)),
  or: (...parts: (Predicate | undefined)[]): Predicate => row => parts.some(part => part !== undefined && part(row)),
  asc: (column: unknown) => ({ column: field(column), direction: 1 }),
  desc: (column: unknown) => ({ column: field(column), direction: -1 }),
  sql: Object.assign((strings: readonly string[], ...values: unknown[]): SqlFragment => ({ [SQL]: true, strings, values }) as SqlFragment, {
    raw: (text: string): SqlFragment => ({ [SQL]: true, strings: [text], values: [] }) as SqlFragment,
  }),
};

// `${column} + 1` is the only computed value the services write.
function evaluate(value: unknown, row: Row): unknown {
  if (!isSql(value)) return value;
  const [column] = value.values;
  if (value.strings.length === 2 && value.strings[0] === '' && value.strings[1]?.trim() === '+ 1' && isColumn(column)) return (row[column.column] as number) + 1;
  throw new Error(`fake-db: cannot evaluate sql ${value.strings.join('?')}`);
}

interface Order {
  column: string;
  direction: number;
}

function ordered(rows: Row[], orderBy: unknown): Row[] {
  const orders = (Array.isArray(orderBy) ? orderBy : orderBy === undefined ? [] : [orderBy]) as Order[];
  if (orders.length === 0) return rows;
  return [...rows].sort((left, right) => {
    for (const { column, direction } of orders) {
      const [a, b] = [left[column] as number, right[column] as number];
      if (a < b) return -direction;
      if (a > b) return direction;
    }
    return 0;
  });
}

function where(value: unknown): Predicate {
  if (value === undefined) return () => true;
  if (typeof value === 'function') return value as Predicate;
  throw new Error('fake-db: a where clause the fake cannot evaluate');
}

const copy = <T>(value: T): T => structuredClone(value);

// The natural keys an upsert conflicts on, per table.
const UNIQUE: Record<string, readonly string[]> = {
  bibleDocuments: ['projectId', 'section', 'slug'],
  entities: ['projectId', 'entityKey'],
  milestones: ['projectId', 'milestoneKey'],
  canonFacts: ['projectId', 'factKey'],
  drafts: ['projectId', 'chapter'],
  draftRevisions: ['draftId', 'revision'],
  briefs: ['projectId', 'chapter'],
  volumes: ['projectId', 'volumeKey'],
};

// Column defaults the services rely on when they insert without them.
const DEFAULTS: Record<string, Row> = {
  refinementProposals: { status: 'pending', autoApplied: false, opResults: null, inverseOps: null, postState: null, opUndo: null, error: null, warnings: null },
  drafts: { title: null, summary: null, revision: 1, saveSeq: 0, status: 'draft', isolated: false, reviewStatus: 'needs_review', approvedRevision: null },
  entities: { status: null, motivation: null, notes: null, body: null },
  milestones: { subjectEntityKey: null, kind: 'custom', reachedChapter: null, boundRevision: null },
};

export class FakeDb {
  tables = new Map<string, Row[]>();
  private nextId = 1000n;

  rows(table: string): Row[] {
    let rows = this.tables.get(table);
    if (!rows) {
      rows = [];
      this.tables.set(table, rows);
    }
    return rows;
  }

  seed(table: string, row: Row): Row {
    const stored = { id: this.nextId++, ...DEFAULTS[table], ...row };
    this.rows(table).push(stored);
    return stored;
  }

  private thenable<T>(run: () => T, extra: Record<string, unknown> = {}): PromiseLike<T> & Record<string, unknown> {
    return {
      ...extra,
      then: (resolve: (value: T) => unknown, reject: (error: unknown) => unknown) => {
        try {
          return Promise.resolve(resolve(run()));
        } catch (error) {
          return Promise.resolve(reject(error));
        }
      },
    } as PromiseLike<T> & Record<string, unknown>;
  }

  private project(rows: Row[], fields: unknown): Row[] {
    if (!fields || typeof fields !== 'object') return rows.map(copy);
    return rows.map(row =>
      Object.fromEntries(
        Object.entries(fields as Record<string, unknown>).map(([name, column]) => {
          if (!isColumn(column)) throw new Error(`fake-db: a computed column ${name}`);
          return [name, copy(row[column.column])];
        }),
      ),
    );
  }

  get query(): Record<string, { findFirst: (options?: Record<string, unknown>) => Promise<Row | undefined>; findMany: (options?: Record<string, unknown>) => Promise<Row[]> }> {
    return new Proxy({} as never, {
      get: (_, table) => ({
        findFirst: async (options: Record<string, unknown> = {}) => {
          const rows = ordered(this.rows(String(table)).filter(where(options['where'])), options['orderBy']);
          return rows[0] === undefined ? undefined : copy(rows[0]);
        },
        findMany: async (options: Record<string, unknown> = {}) => {
          const rows = ordered(this.rows(String(table)).filter(where(options['where'])), options['orderBy']);
          return (typeof options['limit'] === 'number' ? rows.slice(0, options['limit']) : rows).map(copy);
        },
      }),
    });
  }

  select(fields?: unknown) {
    let table = '';
    let predicate: Predicate = () => true;
    let order: unknown;
    let limit: number | undefined;
    const run = (): Row[] => {
      const rows = ordered(this.rows(table).filter(predicate), order);
      return this.project(limit === undefined ? rows : rows.slice(0, limit), fields);
    };
    const chain: Record<string, unknown> = {};
    Object.assign(chain, {
      from: (target: unknown) => {
        table = (target as { [key: string]: Column })['id']?.table ?? '';
        return chain;
      },
      where: (value: unknown) => {
        predicate = where(value);
        return chain;
      },
      orderBy: (...orders: unknown[]) => {
        order = orders;
        return chain;
      },
      limit: (count: number) => {
        limit = count;
        return chain;
      },
      for: () => chain,
      then: (resolve: (value: Row[]) => unknown, reject: (error: unknown) => unknown) => this.thenable(run).then(resolve, reject),
    });
    return chain;
  }

  insert(target: unknown) {
    const table = (target as { [key: string]: Column })['id']?.table ?? '';
    let values: Row[] = [];
    let conflict: { target?: unknown; set?: Row; nothing?: boolean } | undefined;
    let fields: unknown;
    const run = (): Row[] => {
      const written: Row[] = [];
      for (const value of values) {
        const keys = UNIQUE[table];
        const existing = keys ? this.rows(table).find(row => keys.every(key => same(row[key], value[key]))) : undefined;
        if (existing && conflict?.nothing) continue;
        if (existing && conflict?.set) {
          for (const [key, raw] of Object.entries(conflict.set)) existing[key] = evaluate(raw, existing);
          written.push(existing);
          continue;
        }
        if (existing) throw new Error(`fake-db: duplicate ${table} row`);
        written.push(this.seed(table, value));
      }
      return this.project(written, fields);
    };
    const chain: Record<string, unknown> = {};
    Object.assign(chain, {
      values: (value: Row | Row[]) => {
        values = Array.isArray(value) ? value : [value];
        return chain;
      },
      onConflictDoUpdate: (options: { target?: unknown; set: Row }) => {
        conflict = { target: options.target, set: options.set };
        return chain;
      },
      onConflictDoNothing: () => {
        conflict = { nothing: true };
        return chain;
      },
      returning: (projection?: unknown) => {
        fields = projection;
        return chain;
      },
      then: (resolve: (value: Row[]) => unknown, reject: (error: unknown) => unknown) => this.thenable(run).then(resolve, reject),
    });
    return chain;
  }

  update(target: unknown) {
    const table = (target as { [key: string]: Column })['id']?.table ?? '';
    let changes: Row = {};
    let predicate: Predicate = () => true;
    let fields: unknown;
    const run = (): Row[] => {
      const rows = this.rows(table).filter(predicate);
      for (const row of rows) {
        const next = Object.fromEntries(Object.entries(changes).map(([key, raw]) => [key, evaluate(raw, row)]));
        Object.assign(row, next);
      }
      return this.project(rows, fields);
    };
    const chain: Record<string, unknown> = {};
    Object.assign(chain, {
      set: (value: Row) => {
        changes = value;
        return chain;
      },
      where: (value: unknown) => {
        predicate = where(value);
        return chain;
      },
      returning: (projection?: unknown) => {
        fields = projection;
        return chain;
      },
      then: (resolve: (value: Row[]) => unknown, reject: (error: unknown) => unknown) => this.thenable(run).then(resolve, reject),
    });
    return chain;
  }

  delete(target: unknown) {
    const table = (target as { [key: string]: Column })['id']?.table ?? '';
    let predicate: Predicate = () => true;
    let fields: unknown;
    const run = (): Row[] => {
      const rows = this.rows(table);
      const removed = rows.filter(predicate);
      this.tables.set(
        table,
        rows.filter(row => !removed.includes(row)),
      );
      return this.project(removed, fields);
    };
    const chain: Record<string, unknown> = {};
    Object.assign(chain, {
      where: (value: unknown) => {
        predicate = where(value);
        return chain;
      },
      returning: (projection?: unknown) => {
        fields = projection;
        return chain;
      },
      then: (resolve: (value: Row[]) => unknown, reject: (error: unknown) => unknown) => this.thenable(run).then(resolve, reject),
    });
    return chain;
  }

  async $count(target: unknown, predicate?: unknown): Promise<number> {
    const table = (target as { [key: string]: Column })['id']?.table ?? '';
    return this.rows(table).filter(where(predicate)).length;
  }

  async transaction<T>(body: (tx: FakeDb) => Promise<T>): Promise<T> {
    const saved = new Map([...this.tables].map(([table, rows]) => [table, copy(rows)]));
    const savedId = this.nextId;
    try {
      return await body(this);
    } catch (error) {
      this.tables = saved;
      this.nextId = savedId;
      throw error;
    }
  }
}
