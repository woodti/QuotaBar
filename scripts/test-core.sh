#!/bin/bash
# Run the same core cases on Command Line Tools installations without XCTest.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
python3 - "$TEST_TMP/main.swift" <<'PY'
import pathlib, re, sys
source = pathlib.Path('Tests/QuotaCoreTests/QuotaCoreTests.swift').read_text().replace('import XCTest', 'import Foundation').replace('@testable import QuotaCore', '')
shim = r'''
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Equality failed: \(a) != \(b)") }
func XCTAssertTrue(_ b: Bool) { precondition(b) }
func XCTAssertFalse(_ b: Bool) { precondition(!b) }
func XCTAssertNil<T>(_ v: T?) { precondition(v == nil) }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T) { precondition(a < b) }
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T) { do { _ = try body(); fatalError("Expected error") } catch {} }
'''
cases = re.findall(r'func (test\w+)\(\)( throws)?', source)
runner = '\nlet suite = QuotaCoreTests()\n' + '\n'.join(('try ' if throws else '') + 'suite.' + name + '()' for name, throws in cases)
runner += '\nprint("PASS: ' + str(len(cases)) + ' core scenarios")\n'
pathlib.Path(sys.argv[1]).write_text(shim + source + runner)
PY
swiftc Sources/QuotaCore/*.swift "$TEST_TMP/main.swift" -o "$TEST_TMP/core-tests"
"$TEST_TMP/core-tests"
