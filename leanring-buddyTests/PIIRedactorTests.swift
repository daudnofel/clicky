//
//  PIIRedactorTests.swift
//  leanring-buddyTests
//
//  Unit tests for PIIRedactor's heuristic detection of credit card numbers
//  and US SSNs. These patterns gate which text events the teach-mode
//  recorder is allowed to persist to disk.
//

import Testing
@testable import leanring_buddy

struct PIIRedactorTests {

    @Test func detectsCreditCardWithSpaces() async throws {
        #expect(PIIRedactor.looksSensitive("4111 1111 1111 1111"))
    }

    @Test func detectsCreditCardWithDashes() async throws {
        #expect(PIIRedactor.looksSensitive("4111-1111-1111-1111"))
    }

    @Test func detectsCreditCardWithNoSeparators() async throws {
        #expect(PIIRedactor.looksSensitive("4111111111111111"))
    }

    @Test func detectsSocialSecurityNumber() async throws {
        #expect(PIIRedactor.looksSensitive("123-45-6789"))
    }

    @Test func detectsSocialSecurityNumberInsideSentence() async throws {
        #expect(PIIRedactor.looksSensitive("my ssn is 123-45-6789 please don't store it"))
    }

    @Test func ignoresPlainSentence() async throws {
        #expect(!PIIRedactor.looksSensitive("Hello, world."))
    }

    @Test func ignoresPlainUrl() async throws {
        #expect(!PIIRedactor.looksSensitive("https://example.com"))
    }

    @Test func ignoresShortNumericString() async throws {
        // Short numeric strings (zip codes, room numbers, etc.) must not
        // trip the credit-card heuristic — the minimum match length is 13.
        #expect(!PIIRedactor.looksSensitive("94103"))
    }

    @Test func ignoresEmailAddress() async throws {
        #expect(!PIIRedactor.looksSensitive("daud@example.com"))
    }
}
