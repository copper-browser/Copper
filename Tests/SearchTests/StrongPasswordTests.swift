import Foundation
import Testing
@testable import Search

// Suggest strong password (Fork/Credentials/StrongPassword.swift): what a site's
// passwordrules say, and that every password made keeps them.

private func classes(_ password: String) -> Int {
    [PasswordRules.lower, PasswordRules.upper, PasswordRules.digit, PasswordRules.special]
        .filter { !Set(password).isDisjoint(with: $0) }.count
}

@Test func withNoRulesAPasswordHasEveryClassAndNoLongRuns() {
    for _ in 0..<500 {
        let password = StrongPassword.generate()
        #expect(password.count == 20)
        #expect(classes(password) == 4)
        #expect(StrongPassword.longestRun(password) <= 2)
        #expect(Set(password).isSubset(of: PasswordRules.lower.union(PasswordRules.upper)
            .union(PasswordRules.digit).union(PasswordRules.defaultSymbols)))
    }
}

@Test func theBoxesOwnLengthsWin() {
    #expect(StrongPassword.generate(rules: PasswordRules(maxLength: 12)).count == 12)
    #expect(StrongPassword.generate(rules: PasswordRules(minLength: 32)).count == 32)
    // UKG: 15–64, maxlength 65 on the box.
    #expect(StrongPassword.generate(rules: PasswordRules(minLength: 15, maxLength: 65)).count == 20)
}

@Test func passwordrulesAreRead() {
    let rules = PasswordRules(passwordrules: "required: upper; required: lower; required: digit; required: [-().&@?'#,/\"+]; max-consecutive: 2; minlength: 12; maxlength: 16;")
    #expect(rules.minLength == 12)
    #expect(rules.maxLength == 16)
    #expect(rules.maxConsecutive == 2)
    #expect(rules.required.count == 4)
    #expect(rules.required[3] == Set("-().&@?'#,/\"+"))
    for _ in 0..<300 {
        let password = StrongPassword.generate(rules: rules)
        #expect(password.count == 16)
        #expect(!Set(password).isDisjoint(with: rules.required[3]))
        #expect(StrongPassword.longestRun(password) <= 2)
    }
}

@Test func allowedNarrowsThePool() {
    let rules = PasswordRules(passwordrules: "allowed: lower, digit; required: digit; maxlength: 10")
    for _ in 0..<200 {
        let password = StrongPassword.generate(rules: rules)
        #expect(password.count == 10)
        #expect(Set(password).isSubset(of: PasswordRules.lower.union(PasswordRules.digit)))
        #expect(!Set(password).isDisjoint(with: PasswordRules.digit))
    }
}

@Test func bracketSetsKeepTheirLiteralBracketAndDash() {
    #expect(PasswordRules.characters(in: "[]-]") == Set("]-"))
    #expect(PasswordRules.characters(in: "upper, [_]") == PasswordRules.upper.union(["_"]))
    // Junk never loops.
    #expect(PasswordRules.characters(in: "] ,, nonsense") == [])
}

@Test func theUsernameNeverAppears() {
    // A tiny pool makes "abc" likely by chance; it must still never appear.
    let rules = PasswordRules(passwordrules: "allowed: [abc]; maxlength: 12; max-consecutive: 12")
    for _ in 0..<300 {
        #expect(!StrongPassword.generate(rules: rules, avoiding: ["abc"]).contains("abc"))
    }
}
