import SwiftUI

/// Custom vector icons from `Assets.xcassets` (`macos/Icon svg`).
enum AppIcon: String, CaseIterable {
    case askAI = "iconAskAI"
    case add = "iconAdd"
    case bulletList = "iconBulletList"
    case copy = "iconCopy"
    case counter = "iconCounter"
    case delete = "iconDelete"
    case duplicate = "iconDuplicate"
    case editColor = "iconEditColor"
    case export = "iconExport"
    case goToLink = "iconGoToLink"
    case hideVisual = "iconHideVisual"
    case itemColor = "iconItemColor"
    case layerBack = "iconLayerBack"
    case layerUp = "iconLayerUp"
    case numberedList = "iconNumberedList"
    case panelClosed = "iconPanelClosed"
    case panelOpen = "iconPanelOpen"
    case pin = "iconPin"
    case removeFormatting = "iconRemoveFormatting"
    case rename = "iconRename"
    case revealInFinder = "iconRevealInFinder"
    case search = "iconSearch"
    case settings = "iconSettings"
    case textFormat = "iconTextFormat"
    case todoList = "iconTodoList"
    case turnIntoNote = "iconTurnIntoNote"

    var image: Image {
        Image(rawValue)
    }
}

struct AppIconView: View {
    let icon: AppIcon
    var size: CGFloat = 16

    var body: some View {
        icon.image
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
