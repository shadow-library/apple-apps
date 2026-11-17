import { plugin } from 'bun';
import { readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts (the reference schemas use legacy decorators)
const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));
const sdk = await import(join(platformRepo, 'packages/sdk/src/index.ts'));

const commonExports: Record<string, unknown> = {};
for (const file of readdirSync(join(server, 'common')).filter(name => name.endsWith('.ts') && !name.endsWith('.spec.ts') && name !== 'index.ts').sort()) {
  try {
    Object.assign(commonExports, await import(join(server, 'common', file)));
  } catch {
    continue;
  }
}

const BIBLE_SECTIONS = ['project', 'world', 'power', 'plot', 'story_state', 'ai', 'lore'];
const columns = (table: string): unknown =>
  new Proxy({}, { get: (_, column) => (column === 'enumValues' ? BIBLE_SECTIONS : `${table}.${String(column)}`) });
const schema = new Proxy({}, { get: (_, table) => columns(String(table)) });

plugin({
  name: 'prompts-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({ exports: commonExports, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: { bibleSection: { enumValues: BIBLE_SECTIONS } }, loader: 'object' }));
    build.module('@shadow-library/sdk', () => ({ exports: sdk, loader: 'object' }));
  },
});

const prompts = join(server, 'modules/ai/prompts');
const chatRefine = await import(join(prompts, 'chat-refine.prompt.ts'));
const chatCompact = await import(join(prompts, 'chat-compact.prompt.ts'));
const chatTitle = await import(join(prompts, 'chat-title.prompt.ts'));
const playbooks = await import(join(prompts, 'scope-playbooks.ts'));
const preamble = await import(join(prompts, 'authoring-preamble.ts'));
const writing = await import(join(prompts, 'writing-instructions.ts'));
const validate = await import(join(server, 'modules/ai/schemas/validate.ts'));
const refineSchema = await import(join(server, 'modules/ai/schemas/chat-refine.schema.ts'));
const titleSchema = await import(join(server, 'modules/ai/schemas/chat-title.schema.ts'));
const organisePlan = await import(join(server, 'modules/notes/organise-plan.ts'));

const toolFiles = [
  'get-bible-document',
  'get-brief',
  'get-draft',
  'get-entity',
  'get-canon-facts',
  'get-chapter-summaries',
  'get-plot-threads',
  'get-volume',
  'get-notes',
  'get-usage',
];
const tools: any[] = [];
for (const file of toolFiles) {
  const module = await import(join(server, 'modules/ai/tools/tools', `${file}.tool.ts`));
  const tool = Object.values(module).find((value: any) => value && typeof value === 'object' && typeof value.name === 'string' && value.inputSchema);
  if (!tool) throw new Error(`no tool exported by ${file}`);
  tools.push(tool);
}
const byName = (name: string): any => tools.find(tool => tool.name === name);

const DISABLED_LOOKUPS = ['search_lore', 'search_prose', 'get_review', 'get_world_facts', 'get_character_timeline', 'search_web', 'fetch_page'];

const REPLACEMENTS = [
  { from: 'find it with search_lore or the matching lookup rather than inventing a ref.', to: 'find it with the matching lookup rather than inventing a ref.' },
  {
    from: 'get_draft (with get_brief) and get_review for the chapter; get_bible_document, get_entity, get_canon_facts or get_world_facts for the records in question;',
    to: 'get_draft (with get_brief) for the chapter; get_bible_document, get_entity or get_canon_facts for the records in question;',
  },
  {
    from: "naming the chapter's revision (and, when get_review found one, whether it is stale against that revision) and quoting",
    to: "naming the chapter's revision and quoting",
  },
];

function occurrences(text: string, part: string): number {
  return text.split(part).length - 1;
}

function withoutDisabledLookups(text: string): string {
  let adapted = text;
  for (const { from, to } of REPLACEMENTS) {
    if (occurrences(adapted, from) !== 1) throw new Error(`replacement must match exactly once: ${from}`);
    adapted = adapted.replace(from, () => to);
  }
  for (const name of DISABLED_LOOKUPS) if (adapted.includes(name)) throw new Error(`${name} survives the replacements`);
  return adapted;
}

const rawGuidance: string = playbooks.HUB_PLAYBOOK.guidance;
const hubInstructions = withoutDisabledLookups(playbooks.HUB_INSTRUCTIONS);
const adaptedGuidance = withoutDisabledLookups(rawGuidance);

const lookupArgs = (tool: any): string[] | null => (tool.inputSchema.shape ? Object.keys(tool.inputSchema.shape) : null);
const describeTools = (list: any[]) => list.map(tool => ({ name: tool.name, args: lookupArgs(tool), description: tool.description }));

const emptyArgsTool = { ...byName('get_brief'), name: 'get_nothing', description: 'No arguments at all.', inputSchema: byName('get_brief').inputSchema.pick({}) };
const opaqueTool = { ...byName('get_brief'), name: 'get_opaque', description: 'Pairs 🧭 and é and "quotes" — dash.\nSecond line.', inputSchema: byName('get_brief').inputSchema.shape.chapter };
const scopeCases = [
  { name: 'none', list: [] },
  { name: 'one', list: [byName('get_brief')] },
  { name: 'ten', list: tools },
  { name: 'ten-reversed', list: [...tools].reverse() },
  { name: 'shapes', list: [emptyArgsTool, opaqueTool, byName('get_chapter_summaries')] },
].map(({ name, list }) => ({
  name,
  tools: describeTools(list),
  text: withoutDisabledLookups(chatRefine.chatScopeInstructions(list, 'off')),
  rawText: chatRefine.chatScopeInstructions(list, 'off'),
}));
for (const entry of scopeCases) if (entry.rawText.replaceAll(rawGuidance, adaptedGuidance) !== entry.text) throw new Error(`scope case ${entry.name} differs outside the guidance`);

const turnRules: unknown[] = [];
for (const proseEdits of [false, true])
  for (const mode of ['auto', 'manual'])
    for (const justDiscussing of [false, true])
      for (const organiseNotes of [false, true])
        turnRules.push({ proseEdits, mode, justDiscussing, organiseNotes, text: chatRefine.renderTurnRules({ proseEdits, mode, justDiscussing, organiseNotes }) });
for (const proseEdits of [false, true])
  for (const mode of ['auto', 'manual'])
    turnRules.push({ proseEdits, mode, justDiscussing: null, organiseNotes: null, text: chatRefine.renderTurnRules({ proseEdits, mode }) });

const awkward = [
  '',
  'plain',
  'brace {userMessage} and {turnRules} and {volatileContext}',
  'dollar $& $1 $$ $` $\' <>',
  'astral 😀 combining é crlf\r\nline sep nbsp',
  '  edges \n',
];
const turnMessages = awkward.flatMap((volatileContext, index) =>
  [awkward[(index + 1) % awkward.length], awkward[(index + 3) % awkward.length]].map((turnRule, offset) => {
    const parts = { volatileContext, turnRules: turnRule as string, userMessage: awkward[(index + 2 + offset) % awkward.length] as string };
    return { ...parts, text: chatRefine.renderTurnMessage(parts) };
  }),
);

const basePrompt = chatRefine.buildChatRefinePrompt('project', { proseEdits: false });
const roleName = (message: any): string => ({ system: 'system', human: 'user', ai: 'assistant' })[message.getType() as string] as string;
const history = (turns: [string, string][]) => turns.map(([role, text]) => [role === 'user' ? 'human' : 'ai', text]);
const messageCases = [
  { scope: 'Scope text\nwith lines', stable: 'stable {context} 😀', history: [], parts: { volatileContext: 'v', turnRules: 'r', userMessage: 'u' }, rounds: [] },
  {
    scope: '',
    stable: '',
    history: [['user', 'first'], ['assistant', 'reply {with} braces'], ['user', 'second']],
    parts: { volatileContext: '', turnRules: '', userMessage: '' },
    rounds: [['assistant', '{"lookups":[]}'], ['user', 'Lookup results:\n- ok']],
  },
  {
    scope: 'S',
    stable: 'T',
    history: [['user', 'x']],
    parts: { volatileContext: 'ctx $&', turnRules: 'rules', userMessage: 'hello\r\nworld' },
    rounds: [['assistant', 'a']],
  },
];
const messages = [];
for (const entry of messageCases) {
  const formatted = await basePrompt.template.formatMessages({
    scopeInstructions: entry.scope,
    stableContext: entry.stable,
    history: history(entry.history as [string, string][]),
    ...entry.parts,
    rounds: history(entry.rounds as [string, string][]),
  });
  messages.push({ ...entry, expected: formatted.map((message: any) => ({ role: roleName(message), text: message.content })) });
}

const fillers = (template: any, values: Record<string, string>) => template.formatMessages(values);
const compactCases = [
  { priorSummary: '', transcript: '' },
  { priorSummary: 'Accepted: Mira stays. Rejected: the twin.', transcript: 'user: hi\nassistant: hello' },
  { priorSummary: 'brace {transcript} $& 😀', transcript: 'crlf\r\nnbsp {priorSummary}' },
];
const compact = [];
for (const values of compactCases) {
  const formatted = await fillers(chatCompact.chatCompactPrompt.template, values);
  compact.push({ ...values, expected: formatted.map((message: any) => ({ role: roleName(message), text: message.content })) });
}
const titleCases = [{ message: '' }, { message: 'fix this' }, { message: 'Plan volume 2 {pacing} $& 😀\r\nsecond line ' }];
const title = [];
for (const values of titleCases) {
  const formatted = await fillers(chatTitle.chatTitlePrompt.template, values);
  title.push({ ...values, expected: formatted.map((message: any) => ({ role: roleName(message), text: message.content })) });
}

const op = (value: Record<string, unknown>) => value;
const premise = op({ op: 'premise.update', premise: 'A smith finds a map.' });
const entity = op({ op: 'entity.upsert', entityKey: 'mira', type: 'character', name: 'Mira' });
const notAllowedHere = op({ op: 'organise.rule' });
const lookupOk = { tool: 'get_brief', args: { chapter: 3 } };
const outputs: { name: string; output: Record<string, unknown> }[] = [
  { name: 'reply only', output: { reply: 'hello' } },
  { name: 'empty change set', output: { reply: 'hello', changeSet: [] } },
  { name: 'valid change set', output: { reply: 'r', changeSet: [premise, entity] } },
  { name: 'unknown op', output: { reply: 'r', changeSet: [op({ op: 'nope.nope' })] } },
  { name: 'op outside the scope', output: { reply: 'r', changeSet: [notAllowedHere] } },
  { name: 'invalid fields', output: { reply: 'r', changeSet: [op({ op: 'entity.upsert' }), { op: 'premise.update', premise: 4 }, 'text'] } },
  { name: 'prose op', output: { reply: 'r', changeSet: [op({ op: 'draft.rewrite_passage', chapter: 1, passage: 'old', replacement: 'new', contextIndex: 1, label: 'x' })] } },
  { name: 'empty lookups', output: { reply: 'r', lookups: [] } },
  { name: 'empty lookups with change set', output: { reply: 'r', lookups: [], changeSet: [premise] } },
  { name: 'lookups', output: { reply: 'r', lookups: [lookupOk, { tool: 'get_entity' }] } },
  { name: 'lookups with change set', output: { reply: 'r', lookups: [lookupOk], changeSet: [premise] } },
  { name: 'lookups with empty change set', output: { reply: 'r', lookups: [lookupOk], changeSet: [] } },
  { name: 'lookup without a tool name', output: { reply: 'r', lookups: [lookupOk, { tool: '' }] } },
  { name: 'lookup with a non-string tool', output: { reply: 'r', lookups: [{ tool: 4 }] } },
  { name: 'lookup without a tool', output: { reply: 'r', lookups: [{ args: {} }] } },
  { name: 'question card', output: { reply: 'r', question: { question: 'q', answers: [] } } },
];
const scopes = ['project', 'novel', 'bible_document', 'volume', 'brief'];
const validation = outputs.flatMap(({ name, output }) =>
  scopes.map(scope => ({ name, scope, output, errors: chatRefine.buildChatRefinePrompt(scope, { proseEdits: false }).postValidate(structuredClone(output)) })),
);
const baseValidation = outputs.map(({ name, output }) => ({ name, output, errors: chatRefine.chatRefinePrompt.postValidate(structuredClone(output)) }));

const bibleOp = (slug: string, body: string, title?: string) =>
  op({ op: 'bible_document.upsert', section: 'plot', slug, body, ...(title ? { frontmatter: { title } } : {}) });
const adviseOutputs: { name: string; output: Record<string, unknown> }[] = [
  { name: 'reply only', output: { reply: 'r' } },
  { name: 'prose ops', output: { reply: 'r', changeSet: [premise, op({ op: 'draft.update', chapter: 1, body: 'x' }), op({ op: 'draft.rewrite_passage', chapter: 1 })] } },
  { name: 'later plans page', output: { reply: 'r', changeSet: [bibleOp('later-plans', 'The roadmap.'), premise, bibleOp('timeline', '# Plans\nx', 'Upcoming events')] } },
  { name: 'writer-excluded page', output: { reply: 'r', changeSet: [op({ op: 'bible_document.upsert', section: 'plot', slug: 'timeline', body: '# Plans' })] } },
  { name: 'organise only', output: { reply: 'r', changeSet: [op({ op: 'action.organise_notes' })] } },
  { name: 'prose and plans', output: { reply: 'r', changeSet: [op({ op: 'action.revise_draft', chapter: 2 }), bibleOp('plans', 'x')] } },
  { name: 'lookups beside prose', output: { reply: 'r', lookups: [lookupOk], changeSet: [op({ op: 'draft.remove', chapter: 1 })] } },
  { name: 'empty change set', output: { reply: 'r', changeSet: [] } },
];
const advice = [];
for (const proseEdits of [false, true])
  for (const organiseNotes of [false, true, null])
    for (const { name, output } of adviseOutputs) {
      const permissions = organiseNotes === null ? { proseEdits } : { proseEdits, organiseNotes };
      advice.push({ name, proseEdits, organiseNotes, output, issues: chatRefine.buildChatRefinePrompt('project', permissions).advise(structuredClone(output)) });
    }
const permissionless = chatRefine.buildChatRefinePrompt('project');
const defaultAdvice = adviseOutputs.map(({ name, output }) => ({ name, output, issues: permissionless.advise(structuredClone(output)) }));

const wireOverrides = chatRefine.chatRefinePrompt.constrainedProperties;
const schemas = {
  refine: validate.toHostedPromptSchema(refineSchema.ChatRefineSchema),
  refineConstrained: validate.toConstrainedSchema(refineSchema.ChatRefineSchema, wireOverrides),
  compact: validate.toHostedPromptSchema(chatCompact.chatCompactPrompt.schema),
  title: validate.toHostedPromptSchema(titleSchema.ChatTitleSchema),
  titleMaxLength: titleSchema.CHAT_TITLE_MAX_LENGTH,
};

const defaultText: string = preamble.DEFAULT_WRITING_INSTRUCTIONS;
const legacy: string[] = writing.LEGACY_DEFAULT_WRITING_INSTRUCTIONS;
const defaultLines = defaultText.split('\n');
const editLine = (text: string, index: number, replacement: string) => text.split('\n').map((line, at) => (at === index ? replacement : line)).join('\n');
const own = 'Write in second person.\n- Keep chapters short.';
const everyLegacy = [defaultText, ...legacy];
const stored: (string | null | undefined)[] = [
  undefined,
  null,
  '',
  ' ',
  '\n\n',
  own,
  `  ${own}  \r\n`,
  'Rule A\r\n\r\n\r\n\r\nRule B\rRule C',
  'Rule with trailing   \nspaces\t\n and tabs\t',
  'A\n\n\n\n\nB',
  defaultText,
  `${defaultText}\n`,
  defaultText.replaceAll('\n', '\r\n'),
  defaultText.replaceAll('\n', '  \n'),
  `${own}\n\n${defaultText}`,
  `${defaultText}\n\n${own}`,
  `${defaultText}\n\n${defaultText}`,
  `${defaultText}${defaultText}`,
  `before\n${defaultText}\nafter`,
  `Keep it light.\n\n${defaultText}\n\nAlways name the dog.`,
  ...legacy,
  ...legacy.map(text => `${own}\n\n${text}`),
  ...legacy.map(text => text.replaceAll('\n', '\r\n')),
  `${legacy[0]}\n\n${legacy[1]}`,
  `${legacy[2]}\n\n${own}\n\n${legacy[3]}`,
  editLine(defaultText, 3, 'Clarity!'),
  editLine(defaultText, 10, '- A line the author wrote.'),
  editLine(legacy[1] as string, 4, '- Use common words.'),
  editLine(legacy[3] as string, 9, '- Keep most sentences between roughly 6 and 40 words.'),
  defaultLines.slice(0, 20).join('\n'),
  defaultLines.slice(0, 40).join('\n'),
  defaultLines.slice(0, 60).join('\n'),
  `${defaultLines.slice(0, 30).join('\n')}\n${own}`,
  `${defaultLines.slice(0, 55).join('\n')}\n${own}\n${defaultLines.slice(70).join('\n')}`,
  defaultLines.filter((_, index) => index % 2 === 0).join('\n'),
  defaultLines.filter((_, index) => index % 3 !== 0).join('\n'),
  defaultLines.map(line => `${line}   `).join('\n'),
  defaultLines.map(line => line.replaceAll(' ', ' ')).join('\n'),
  defaultLines.map(line => line.replaceAll(' ', '  ')).join('\n'),
  defaultLines.map(line => `\t${line}`).join('\n'),
  `${own}\n- ${'Café \u{1f600} é'}\n  indented line`,
  everyLegacy.join('\n'),
  everyLegacy.join('\n\n\n'),
  everyLegacy.map(text => `x\n${text}`).join('\n'),
  'DEFAULT WEB-NOVEL ENGLISH',
  'DEFAULT WEB-NOVEL ENGLISH\n\nClarity\n- Keep most sentences between roughly 6 and 22 words.\n- Mine.',
];
const resolved = stored.map(text => ({ stored: text ?? null, undefinedInput: text === undefined, result: writing.resolveWritingInstructions(text), additions: writing.writingInstructionAdditions(text) }));
const effective = [null, '', own, `${own}\n\n\n\nSecond paragraph`, 'Café 😀'].map(additions => ({ additions, result: writing.effectiveWritingInstructions(additions) }));

const sections = [
  'authoringStyle',
  'authoringStylePlanning',
  'editByDeletion',
  'clueDiscipline',
  'systemPanels',
  'authoringStyleRepair',
  'defaultWritingInstructions',
  'bibleStageOutputShape',
];
const preambleTexts = Object.fromEntries(
  sections.map(key => {
    const name = key.replace(/[A-Z]/g, letter => `_${letter}`).toUpperCase();
    const text = preamble[name];
    if (typeof text !== 'string') throw new Error(`authoring-preamble.ts exports no ${name}`);
    return [key, text];
  }),
);

const output = {
  deviations: { disabledLookups: DISABLED_LOOKUPS, replacements: REPLACEMENTS, rawGuidance, rawInstructions: playbooks.HUB_INSTRUCTIONS },
  constants: {
    chatRefineSystem: chatRefine.chatRefinePrompt.system,
    chatRefineVersion: chatRefine.chatRefinePrompt.version,
    chatRefineStableMessages: chatRefine.chatRefinePrompt.cacheStrategy.stableMessages,
    chatRefineStableVars: chatRefine.chatRefinePrompt.cacheStrategy.stableVars,
    chatCompactSystem: chatCompact.chatCompactPrompt.system,
    chatCompactVersion: chatCompact.chatCompactPrompt.version,
    chatTitleSystem: chatTitle.chatTitlePrompt.system,
    chatTitleVersion: chatTitle.chatTitlePrompt.version,
    hubGuidance: adaptedGuidance,
    hubInstructions,
    hubAllowedOps: playbooks.HUB_ALLOWED_OPS,
    hubContentOps: playbooks.HUB_PLAYBOOK.allowedOps,
    organiseMinWords: organisePlan.ORGANISE_MIN_WORDS,
    projectAdditionsHeading: writing.PROJECT_ADDITIONS_HEADING,
    legacyDefaults: legacy,
    preamble: preambleTexts,
  },
  scopeInstructions: scopeCases.map(({ name, tools: list, text }) => ({ name, tools: list, text })),
  turnRules,
  turnMessages,
  messages,
  compact,
  title,
  validation: { hub: validation, base: baseValidation },
  advice: { cases: advice, defaults: defaultAdvice },
  schemas,
  writing: { resolved, effective },
};

writeFileSync(join(outDir, 'prompts.json'), `${JSON.stringify(output)}\n`);
console.log(`scope ${scopeCases.length}, rules ${turnRules.length}, messages ${turnMessages.length}+${messages.length}, validation ${validation.length + baseValidation.length}, advice ${advice.length}, writing ${resolved.length}`);
