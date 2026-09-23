import MultiModalKit
import SwiftUI

/// THE THREE TABS, AND THE ONE LAUNCH (AC-142).
///
/// ## Why the launch lives here and nowhere else
///
/// The sequence below is order-critical, and the order is a memory bug when
/// reversed. The neural voice compiles six CoreML models CONCURRENTLY, and
/// that transient peak — not its 111 MB finished size — is what killed this
/// app twice, at 1105 MB free and at 2976 MB free. It survived at 3347. So
/// the voice is prepared FIRST, from maximum headroom, and only then does
/// the mind take its 2.2 GB (INSTRUMENTS §29).
///
/// One screen made that easy: one `.task`, one launch. Three tabs make it a
/// hazard, because a `.task` on each tab runs the sequence again — and
/// running it twice is not a slow start, it is the kill. Worse, a naive
/// `didLaunch` flag does not help: two tabs appearing together would both
/// read `false` and both begin.
///
/// So the guard is `LaunchOnce`, which makes the second caller WAIT for the
/// first and then find the work already done. It is tested on a Mac with no
/// models installed (`LaunchOnceTests`), including the concurrent case and
/// the order itself.
struct RootView: View {
    @State private var model = TranscribeModel()
    // The 4f measurement instrument, held beside the model rather than
    // inside it: it probes a SYSTEM service, touches nothing on the
    // pipeline, and leaves with the milestone-gating numbers (AC-110/111).
    @State private var mindProbe = MindProbe()
    /// The Models tab's rows (5a, AC-300), built from the app's OWN
    /// engines so the screen reports on the objects the pipeline uses.
    @State private var models = ModelsState()
    private let launch = LaunchOnce()

    var body: some View {
        TabView {
            ChatTab(model: model)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            BenchTab(model: model, mindProbe: mindProbe)
                .tabItem { Label("Bench", systemImage: "gauge.with.needle") }
            ModelsTab(models: models)
                .tabItem { Label("Models", systemImage: "arrow.down.circle") }
            SettingsTab(model: model)
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .task {
            await launch.run([
                // A previous probe's trail, INCLUDING one that ended in a
                // kill — read back before anything else so the evidence of
                // a death survives the death.
                { await model.loadPreviousProbe() },
                // THE GPU GUARD FIRST, before anything can touch Metal
                // (D-079, the review's blocker). `refreshMind()` below
                // prewarms MLX during launch, seconds before anyone can
                // tap Listen — so arming this inside `start()` watched
                // everything except the window where the crash was most
                // likely.
                { await model.observeForegroundLoss() },
                // Both models are asked about at launch: the transcriber's
                // and the voice's. Asking never downloads either.
                { await model.checkModel() },
                // The Models tab's rows: the app's own engines, as
                // `any ModelBacked`. Built here rather than in the tab so
                // the screen and the pipeline cannot disagree about which
                // objects they are talking about.
                { await models.adopt(model.modelRows) },
                // ↓ MUST PRECEDE THE MIND. Swapping these two lines is a
                //   memory bug that looks like nothing.
                { await model.checkVoice() },
                { await model.refreshMind() }
            ])
        }
    }
}
