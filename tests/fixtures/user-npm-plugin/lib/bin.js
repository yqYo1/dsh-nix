#!/usr/bin/env node
import { checkOdd } from './index.js';
const arg = process.argv[2];
if (arg === 'status') {
  console.log('dsh-poc-npm-plugin: signed out');
  process.exit(1);
} else if (arg === '--help' || arg === undefined) {
  console.log('Usage: dsh-poc-npm-plugin [--help|status|check <n>]');
  process.exit(0);
} else if (arg === 'check') {
  const n = Number(process.argv[3]);
  console.log(checkOdd(n) ? 'odd' : 'even');
  process.exit(0);
} else {
  console.error(`unknown command: ${arg}`);
  process.exit(2);
}
