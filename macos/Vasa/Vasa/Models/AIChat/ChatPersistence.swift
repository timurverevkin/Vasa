import Foundation

/// chat.json lives beside board.json in the same lesson directory.
enum ChatPersistence {
    static func chatFile(for lesson: Lesson, subjects: [Subject]) -> URL {
        Persistence.lessonDirectory(lesson, subjects: subjects).appendingPathComponent("chat.json")
    }

    static func load(lesson: Lesson, subjects: [Subject]) -> ChatThread? {
        guard let data = try? Data(contentsOf: chatFile(for: lesson, subjects: subjects)) else { return nil }
        return try? JSONDecoder().decode(ChatThread.self, from: data)
    }

    static func prepareWrite(_ thread: ChatThread, lesson: Lesson, subjects: [Subject]) -> (URL, Data)? {
        guard let data = try? JSONEncoder().encode(thread) else { return nil }
        return (chatFile(for: lesson, subjects: subjects), data)
    }
}
