import Synchronization

/// The models each way of reaching a model offers, kept so requests send only an effort the model accepts.
final class ModelCatalog: Sendable {
    enum Route: Hashable, Sendable {
        case claudeAPI, claudeCode, openAIAPI, chatGPT
    }

    private let models = Mutex<[Route: [ModelOption]]>([
        .claudeAPI: ModelOption.claudeAPIDefaults,
        .openAIAPI: ModelOption.openAIAPIModels,
    ])

    func update(_ options: [ModelOption], for route: Route) {
        models.withLock { $0[route] = options }
    }

    /// Effort levels of a model: nil when the model is not listed yet.
    func efforts(for route: Route, model: String) -> [String]? {
        let options = models.withLock { $0[route] } ?? []
        // An empty model is the provider's default: the first model a ChatGPT account lists.
        let id = model.isEmpty ? (route == .openAIAPI ? ModelOption.openAIAPIDefault.id : options.first?.id) : model
        return options.first { $0.id == id }?.efforts
    }
}
