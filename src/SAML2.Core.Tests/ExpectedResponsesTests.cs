/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Xml;
using NUnit.Framework;
using SAML2.Config;
using SAML2.Logging;
using SAML2.Protocol;

namespace SAML2.Core.Tests
{
    /// <summary>
    /// Regression tests for the process-wide expected-response store that
    /// <see cref="Utility"/> falls back on when no session is available. The store is static,
    /// so these tests share it with each other and use freshly generated ids to stay
    /// independent. See CHANGELOG-VENDAVO.md for the defects they cover.
    /// </summary>
    [TestFixture]
    public class ExpectedResponsesTests
    {
        private static readonly int Threads = Math.Max(8, Environment.ProcessorCount * 2);

        [OneTimeSetUp]
        public void SeedLoggerConfiguration()
        {
            // The static initializer of Utility asks LoggerProvider for a logger, and the lazy
            // factory dereferences LoggerProvider.Configuration, which nothing sets outside a
            // hosted application. An empty configuration leaves LoggingFactoryType empty,
            // which selects NoLoggingLoggerFactory.
            LoggerProvider.Configuration = new Saml2Configuration();
        }

        /// <summary>
        /// A HashSet torn by unsynchronised concurrent adds throws IndexOutOfRangeException or
        /// ArgumentException out of AddIfNotPresent while it grows. In production that took
        /// down the redirect to the identity provider, because an unauthenticated page load
        /// issues a challenge per parallel request.
        /// </summary>
        [Test]
        public void AddExpectedResponseId_ConcurrentCalls_DoNotThrow()
        {
            var failures = new List<Exception>();
            var options = new ParallelOptions { MaxDegreeOfParallelism = Threads };

            Parallel.For(0, 100000, options, i =>
            {
                try
                {
                    Utility.AddExpectedResponseId(NewId());
                }
                catch (Exception ex)
                {
                    lock (failures)
                    {
                        failures.Add(ex);
                    }
                }
            });

            // Asserting on the count rather than on the collection: a torn store fails tens of
            // thousands of calls and dumping every exception buries the one that matters.
            Assert.That(failures.Count, Is.Zero, FirstFailure(failures));
        }

        /// <summary>
        /// An id may be consumed exactly once. Checking membership and removing in two steps
        /// lets two responses carrying the same InResponseTo both pass, which is the replay
        /// this check exists to prevent; accepting nobody would reject a legitimate response.
        /// </summary>
        [Test]
        public void CheckReplayAttack_ConcurrentConsumersOfOneId_AcceptExactlyOne()
        {
            for (var round = 0; round < 200; round++)
            {
                var id = NewId();
                Utility.AddExpectedResponseId(id);

                var accepted = 0;
                var unexpected = new List<Exception>();

                // Real threads and a barrier, so the contention is genuine: a thread pool
                // cannot be relied on to release all participants of a barrier at once.
                using (var gate = new Barrier(Threads))
                {
                    var crew = new Thread[Threads];

                    for (var t = 0; t < Threads; t++)
                    {
                        crew[t] = new Thread(() =>
                        {
                            var response = ResponseWith(id);

                            gate.SignalAndWait();

                            try
                            {
                                Utility.CheckReplayAttack(response, true, null);
                                Interlocked.Increment(ref accepted);
                            }
                            catch (Saml20Exception)
                            {
                                // Expected of every thread that did not win the id.
                            }
                            catch (Exception ex)
                            {
                                lock (unexpected)
                                {
                                    unexpected.Add(ex);
                                }
                            }
                        });

                        crew[t].IsBackground = true;
                        crew[t].Start();
                    }

                    foreach (var thread in crew)
                    {
                        thread.Join();
                    }
                }

                Assert.That(unexpected.Count, Is.Zero, FirstFailure(unexpected));
                Assert.That(accepted, Is.EqualTo(1), "round " + round + " accepted " + accepted + " consumers of one id");
            }
        }

        /// <summary>
        /// One session can issue more than one AuthnRequest - parallel requests from a single
        /// page load, or a retried login - and adding the key a second time threw
        /// ArgumentException. The most recent request wins.
        /// </summary>
        [Test]
        public void AddExpectedResponse_SecondRequestInTheSameSession_ReplacesTheFirst()
        {
            var session = new Dictionary<string, object>();

            Utility.AddExpectedResponse(new Saml20AuthnRequest { Id = "first" }, session);
            Utility.AddExpectedResponse(new Saml20AuthnRequest { Id = "second" }, session);

            Assert.That(session, Has.Count.EqualTo(1));
            Assert.That(session.Values, Is.EqualTo(new[] { "second" }));
        }

        private static string NewId()
        {
            return "regression-" + Guid.NewGuid().ToString("N");
        }

        private static XmlElement ResponseWith(string inResponseTo)
        {
            var document = new XmlDocument();
            var response = document.CreateElement("Response");
            response.SetAttribute("InResponseTo", inResponseTo);

            return response;
        }

        private static string FirstFailure(List<Exception> failures)
        {
            lock (failures)
            {
                return failures.Count == 0 ? string.Empty : "first failure: " + failures[0];
            }
        }
    }
}
