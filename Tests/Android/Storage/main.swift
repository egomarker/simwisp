import Foundation
import Darwin
do { print("\(try runRawStorageTests()) RAW storage/ownership/encoder checks passed") }
catch { fputs("FAIL \(error.localizedDescription)\n",stderr);exit(1) }
