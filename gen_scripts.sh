#!/bin/sh
# js/*.js → DropFill/Scripts.swift (raw string literals)
set -e
cd "$(dirname "$0")"
{
  echo '// 자동 생성 파일 — js/ 폴더를 고친 뒤 ./gen_scripts.sh 실행'
  echo 'enum Scripts {'
  echo '    static let autofill = ##"""'
  cat js/autofill.js
  echo '"""##'
  echo ''
  echo '    static let hook = ##"""'
  cat js/hook.js
  echo '"""##'
  echo ''
  echo '    static let gate = ##"""'
  cat js/gate.js
  echo '"""##'
  echo '}'
} > DropFill/Scripts.swift
