import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const SERVER = 'apps/novel-forge-server/src';

const FILES = [
  `${SERVER}/modules/bible/fact/writer-disclosure-policy.ts`,
  `${SERVER}/modules/bible/fact/knowledge-view.ts`,
  `${SERVER}/common/reveal-rule.ts`,
  `${SERVER}/common/unlock-condition.ts`,
  `${SERVER}/common/reveal-term.ts`,
  `${SERVER}/common/term-text.ts`,
  `${SERVER}/modules/ai/hard-line.ts`,
  `${SERVER}/modules/ai/graphs/mechanical-check.ts`,
  `${SERVER}/modules/ai/graphs/readability-check.ts`,
  `${SERVER}/modules/eval/deterministic-metrics.ts`,
  `${SERVER}/modules/eval/chapter-prose.ts`,
  `${SERVER}/modules/refinement/write-policy.ts`,
  `${SERVER}/modules/refinement/negation-echo.ts`,
  `${SERVER}/modules/refinement/idea-id.ts`,
  `${SERVER}/modules/refinement/idea-filter.ts`,
  `${SERVER}/modules/refinement/idea-rejections.ts`,
  'packages/sdk/src/prose-paragraphs.ts',
  `${SERVER}/modules/generation/passage-anchor.ts`,
  `${SERVER}/modules/refinement/passage-context.ts`,
  `${SERVER}/common/content-hash.ts`,
  `${SERVER}/common/draft-staleness.ts`,
  `${SERVER}/common/plan-state.ts`,
  `${SERVER}/common/provisional-knowledge.ts`,
  `${SERVER}/common/batch-selection.ts`,
  `${SERVER}/common/teaching-gate.ts`,
  `${SERVER}/common/volume-stats.ts`,
  `${SERVER}/common/promise.ts`,
  `${SERVER}/common/progress.ts`,
];

const FEATURES: readonly [string, RegExp][] = [
  ['lookbehind', /\(\?<[=!]/],
  ['lookahead', /\(\?[=!]/],
  ['named-group', /\(\?<[A-Za-z_$]/],
  ['named-backreference', /\\k</],
  ['backreference', /\\[1-9]/],
  ['unicode-property', /\\[pP]\{/],
  ['word-boundary', /\\[bB]/],
  ['lazy-quantifier', /[*+?}]\?/],
  ['anchor', /\^|\$/],
  ['non-ascii-literal', /[^\x00-\x7F]/],
];

interface RegexEntry {
  location: string;
  kind: 'literal' | 'constructor';
  source: string | null;
  flags: string | null;
  expression?: string;
  resolved?: string;
  note?: string;
  features: string[];
}

function features(text: string, flags: string | null): string[] {
  const found = FEATURES.filter(([, pattern]) => pattern.test(text)).map(([name]) => name);
  return [...found, ...(flags ?? '').split('').filter(Boolean).map(flag => `flag-${flag}`)];
}

async function loadTypeScript(repo: string): Promise<typeof import('typescript')> {
  const module = await import(join(repo, 'node_modules/typescript/lib/typescript.js'));
  return module.default ?? module;
}

async function main(): Promise<void> {
  const repo = process.env['PLATFORM_REPO'];
  if (!repo) throw new TypeError('PLATFORM_REPO must name the reference checkout');
  const ts = await loadTypeScript(repo);
  const entries: RegexEntry[] = [];

  for (const path of FILES) {
    const text = readFileSync(join(repo, path), 'utf8');
    const file = ts.createSourceFile(path, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    const constants = new Map<string, string>();
    const locate = (node: import('typescript').Node): string => `${path}:${file.getLineAndCharacterOfPosition(node.getStart(file)).line + 1}`;

    const staticText = (node: import('typescript').Expression): string | null => {
      if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text;
      if (ts.isIdentifier(node)) return constants.get(node.text) ?? null;
      return null;
    };

    const resolve = (node: import('typescript').Expression): string => {
      const known = staticText(node);
      if (known !== null) return known;
      if (ts.isTemplateExpression(node)) {
        return node.head.text + node.templateSpans.map(span => `${resolve(span.expression)}${span.literal.text}`).join('');
      }
      return `\${${node.getText(file)}}`;
    };

    const collectConstants = (node: import('typescript').Node): void => {
      if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) {
        const value = ts.isTemplateExpression(node.initializer) ? resolve(node.initializer) : staticText(node.initializer);
        if (value !== null && !value.includes('${')) constants.set(node.name.text, value);
      }
      ts.forEachChild(node, collectConstants);
    };
    collectConstants(file);

    const visit = (node: import('typescript').Node): void => {
      if (node.kind === ts.SyntaxKind.RegularExpressionLiteral) {
        const literal = node.getText(file);
        const slash = literal.lastIndexOf('/');
        const source = literal.slice(1, slash);
        const flags = literal.slice(slash + 1);
        entries.push({ location: locate(node), kind: 'literal', source, flags, features: features(source, flags) });
      }
      const isConstructor = (ts.isNewExpression(node) || ts.isCallExpression(node)) && ts.isIdentifier(node.expression) && node.expression.text === 'RegExp';
      if (isConstructor) {
        const [patternArgument, flagsArgument] = node.arguments ?? [];
        const source = patternArgument ? staticText(patternArgument) : '';
        const flags = flagsArgument ? staticText(flagsArgument) : '';
        const entry: RegexEntry = { location: locate(node), kind: 'constructor', source, flags, features: [] };
        if (source === null || flags === null) {
          entry.expression = node.arguments?.map(argument => argument.getText(file)).join(', ') ?? '';
          entry.resolved = patternArgument ? resolve(patternArgument) : '';
          entry.note = 'built at run time: `resolved` inlines the file-level string constants and keeps every other part as ${expression}';
        }
        entry.features = features(entry.resolved ?? source ?? '', flags);
        entries.push(entry);
      }
      ts.forEachChild(node, visit);
    };
    visit(file);
  }

  const output = { files: FILES, count: entries.length, regexes: entries };
  writeFileSync(join(import.meta.dir, 'reference-regexes.json'), `${JSON.stringify(output, null, 2)}\n`);
}

await main();
