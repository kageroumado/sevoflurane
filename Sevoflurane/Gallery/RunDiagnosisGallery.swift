#if DEBUG
    import Foundation

    /// One run for every cause ``RunDiagnosis`` knows, each on the panel it
    /// leads: the gallery draws them and ``GalleryExport`` writes each as
    /// `view-run-<cause>.png`.
    @MainActor
    enum RunDiagnosisFixtures {
        struct Panel: Identifiable {
            /// The file's name after `view-run-`: the cause's raw value.
            let id: String
            let record: RunRecord
            let findings: [RunDiagnosis.Finding]
            let model: RunDiagnosisModel

            /// - Parameter shares: Whether the run could be reported to the
            ///   community database, which adds the verdict fields.
            init(_ id: String, _ record: RunRecord, context: RunDiagnosis.Context = .init(), shares: Bool = false) {
                self.id = id
                self.record = record
                findings = RunDiagnosis.findings(for: record, in: context)
                model = RunDiagnosisModel(
                    record: record,
                    findings: findings,
                    report: ReportSendModel(
                        record: record,
                        bundle: { _ in throw CocoaError(.featureUnsupported) },
                        upload: ReportUpload(installToken: "gallery", version: "0+0"),
                        report: RunReportModel(
                            record: record, sharing: shares,
                            ledger: URL(fileURLWithPath: "/dev/null/reported.json"), submit: { _, _ in },
                        ),
                    ),
                    defaults: scratchDefaults,
                    settings: InMemorySettingsEnvironment(),
                    dependencies: dependencies,
                    ledger: nil,
                )
            }
        }

        /// A suite nothing else reads, so a press in the gallery mutes no real game.
        private static let scratchDefaults = UserDefaults(suiteName: "glass.kagerou.sevoflurane.gallery") ?? .standard

        private static let dependencies = DemoCompatibilityEnvironment(scenario: .fresh)

        /// Every panel: one per cause, then a run with several findings.
        static var panels: [Panel] {
            causes + [several]
        }

        /// One per cause, in ``RunDiagnosis/order``.
        static let causes: [Panel] = [
            Panel(RunDiagnosis.Cause.kernelDriver.rawValue, run(
                2_000_000_001, "Genshin Impact", exe: "GenshinImpact.exe", lasting: 60, exit: nil,
            ) { $0.driver = "HoYoKProtect.sys" }),
            Panel(RunDiagnosis.Cause.missingLibrary.rawValue, run(
                410_900, "Forts", exe: "Forts.exe", lasting: 2, exit: .init(kind: .crash, code: -1_073_741_515),
            ) {
                $0.missingDLL = "MSVCP140.dll"
                $0.crash = RunRecord.Crash(code: "0xc0000135", flags: nil, address: nil, module: nil)
            }),
            Panel(RunDiagnosis.Cause.videoDecodedNothing.rawValue, run(
                3_224_770, "Umamusume: Pretty Derby", lasting: 240, exit: .init(kind: .user, code: 0),
            ) { $0.video = RunRecord.Video(buffers: 30, stream: "video/x-h264", decoding: "hardware") }),
            Panel(
                RunDiagnosis.Cause.suggestedFix.rawValue,
                run(4_348_910, "Probably Stolen", lasting: 312, exit: .init(kind: .crash, code: 3)) {
                    $0.renderer = "d3dmetal"
                },
                context: RunDiagnosis.Context(suggested: [suggestion]),
            ),
            Panel(RunDiagnosis.Cause.unityStartup.rawValue, run(
                508_440, "Totally Accurate Battle Simulator", lasting: 8, exit: .init(kind: .exitError, code: 1),
            ) { $0.runtime = "unity" }),
            Panel(RunDiagnosis.Cause.unrealException.rawValue, run(
                1_962_700, "Subnautica 2", lasting: 61, exit: .init(kind: .crash, code: 3),
            ) {
                $0.runtime = "unreal"
                $0.windowAfterSeconds = 9
            }),
            Panel(RunDiagnosis.Cause.stalled.rawValue, run(
                2_358_720, "Black Myth: Wukong", lasting: 1260, exit: .init(kind: .watchdog, code: nil),
            ) { $0.stalls = [RunRecord.Stall(at: 1215, duration: 45, unwedged: nil)] }),
            Panel(RunDiagnosis.Cause.crashed.rawValue, run(
                892_970, "Valheim", lasting: 754, exit: .init(kind: .crash, code: -1_073_741_819),
            ) {
                $0.crash = RunRecord.Crash(code: "0xc0000005", flags: nil, address: "0x7ff6a1b2c3d4", module: "UnityPlayer.dll")
            }, shares: true),
            Panel(RunDiagnosis.Cause.quitWhileStarting.rawValue, run(
                427_520, "Factorio", lasting: 8, exit: .init(kind: .exitError, code: 1),
            )),
            Panel(RunDiagnosis.Cause.notAnswering.rawValue, run(
                339_800, "HuniePop", lasting: 540, exit: .init(kind: .endedNotResponding, code: nil),
            )),
            Panel(RunDiagnosis.Cause.threadSpin.rawValue, run(
                310_360, "Higurashi When They Cry Hou", lasting: 1800, exit: .init(kind: .user, code: 0),
            ) { $0.threads = RunRecord.Threads(busy: 15, processors: 16, samples: 420) }),
            Panel(RunDiagnosis.Cause.droppedShader.rawValue, run(
                1_868_140, "DAVE THE DIVER", lasting: 900, exit: .init(kind: .user, code: 0),
            ) { $0.notes = ["Shader not found? ×12"] }),
            Panel(RunDiagnosis.Cause.unexplained.rawValue, run(
                1_245_620, "ELDEN RING", lasting: 3600, exit: .init(kind: .user, code: 0),
            )),
        ]

        /// A crash on a run that also kept its threads busy and dropped a pass.
        static let several = Panel("several", run(
            310_360, "Higurashi When They Cry Hou", lasting: 1800, exit: .init(kind: .crash, code: 3),
        ) {
            $0.threads = RunRecord.Threads(busy: 15, processors: 16, samples: 420)
            $0.notes = ["Shader not found? ×12"]
        })

        /// The suggestion `OPEN-ISSUES.md` holds ready: two Macs, 11 of 15
        /// D3DMetal runs crashed, none on DXMT.
        static let suggestion = SuggestedFix(
            fix: KnownFix(
                appID: 4_348_910, exePattern: nil, title: "Probably Stolen",
                values: ConfigValues(renderer: .dxmt),
                reason: "Crashes on D3DMetal within minutes; sessions of hours on DXMT.",
            ),
            evidence: FixEvidence(
                macs: 2,
                without: .init(values: ConfigValues(renderer: .d3dmetal), runs: 15, failed: 11),
                with: .init(values: nil, runs: 6, failed: 0),
            ),
        )

        private static func run(
            _ appID: Int, _ name: String, exe: String? = nil, lasting seconds: Double, exit: RunRecord.Exit?,
            _ change: (inout RunRecord) -> Void = { _ in },
        ) -> RunRecord {
            var record = RunRecord(
                t: "2026-11-23T10:00:00Z",
                appid: appID,
                name: name,
                exe: exe,
                engine: "dormison-r14",
                renderer: "dxmt",
                rendererConfirmed: true,
                runner: "wine",
                windows: "fixed",
                msync: true,
                macos: "27.0",
                durationSeconds: seconds,
                exit: exit,
                host: RunRecord.Host(thermal: "nominal", load: 1.2),
            )
            change(&record)
            return record
        }
    }
#endif
