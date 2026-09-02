# Vendavo changes to this fork

Fork of [elerch/SAML2](https://github.com/elerch/SAML2), licensed under the
Mozilla Public License 2.0. The upstream licence continues to apply to every file in
this repository; see `LICENSE`. Modified files carry the MPL 2.0 notice (Exhibit A).

Base commit: `df34ed8` (upstream `master`, the commit the published SAML2.Core 1.0.0
and Owin.Security.Saml 1.0.0 packages were built from).

## 1.0.0-vendavo.1

`src/SAML2.Core/Protocol/Utility.cs` - make the session-less expected-response store
thread safe.

* `expectedResponses` was a `static readonly HashSet<string>` mutated without
  synchronisation from `AddExpectedResponseId` and `CheckReplayAttack`. It is process-wide
  state and `HashSet<T>` is not thread safe, so concurrent AuthnRequest builds tore its
  internal `m_buckets` / `m_slots` arrays. The observed symptom was
  `IndexOutOfRangeException` inside `HashSet<T>.AddIfNotPresent`, thrown out of
  `Owin.Security.Saml.SamlMessage.AuthnRequestForIdp` while building the redirect to the
  IdP; once corrupted the set kept failing until the process was recycled. Replaced with
  `ConcurrentDictionary<string, DateTime>`.
* `CheckReplayAttack` checked membership and removed in two steps, which let two
  concurrent responses carrying the same `InResponseTo` both pass. Now a single atomic
  `TryRemove`.
* Ids of logins that are started but never completed accumulated for the lifetime of the
  process. They are now purged once more than 1000 are retained and older than 8 hours.
  An id that is still present is accepted regardless of age, so no login that previously
  succeeded starts failing.
* `AddExpectedResponse` used `session.Add(...)`, which throws `ArgumentException` when one
  session issues a second AuthnRequest (parallel requests from a single page load, or a
  retried login). Now assigns through the indexer.

No public API signatures changed; the assembly stays binary compatible with
`Owin.Security.Saml` 1.0.0.
