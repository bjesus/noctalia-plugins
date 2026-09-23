--!nonstrict

shortcut.setLabel(noctalia.tr("shortcut.panel_label"))
shortcut.setIcon("layout-list")
shortcut.setActive(false)
shortcut.setEnabled(true)

function onClick()
    noctalia.togglePanel("bjesus/ha-ma:entity_manager")
end
