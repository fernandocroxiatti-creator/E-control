import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import ts from 'typescript';

test('Server Action modules export only async runtime functions', () => {
  for (const name of readdirSync('app/actions').filter(name => name.endsWith('.ts'))) {
    const source = ts.createSourceFile(name, readFileSync(`app/actions/${name}`, 'utf8'), ts.ScriptTarget.Latest, true);
    if (!source.statements.some(statement => ts.isExpressionStatement(statement) && ts.isStringLiteral(statement.expression) && statement.expression.text === 'use server')) continue;
    for (const statement of source.statements) {
      if (ts.isExportDeclaration(statement)) {
        assert.ok(statement.isTypeOnly, `${name}: runtime re-exports require explicit async actions`);
        continue;
      }
      if (!statement.modifiers?.some(modifier => modifier.kind === ts.SyntaxKind.ExportKeyword)) continue;
      if (ts.isTypeAliasDeclaration(statement) || ts.isInterfaceDeclaration(statement)) continue;
      assert.ok(ts.isFunctionDeclaration(statement) && statement.modifiers.some(modifier => modifier.kind === ts.SyntaxKind.AsyncKeyword), `${name}: invalid runtime export ${statement.getText(source).slice(0, 100)}`);
    }
  }
});
