-- GUI 的公共骨架：弹窗容器和名字常量。
--
-- 单独成一个【叶子模块】（不 require 任何东西）是有意的：
-- 几个窗口模块（hud / convert / travel / exp / help / claim）和 init.lua 都要用这些辅助，若把它们留在 init.lua 里，
-- 子模块就得反过来 require init，形成循环依赖。
-- Factorio 又禁止在函数体内 require（只能在模块顶层），所以那种循环无法绕开，
-- 只能从依赖图上消掉 —— 抽成叶子模块就是消掉它的办法。
local M = {}

M.HUD_NAME = 'pw_hud'
M.POPUP_NAME = 'pw_popup'

-- 所有弹窗的统一宽度（像素）。设在内容容器 inner 上而不是 frame 上，
-- 让 frame 自己按内容加边距、标题栏；inner 才是真正决定"看起来多宽"的那一层。
M.WIDTH = 520

-- 关掉可能已存在的弹窗，保证同时只有一个，不会叠罗汉
function M.close_popup(player)
    local existing = player.gui.screen[M.POPUP_NAME]
    if existing then existing.destroy() end
end

-- 建一个居中的空弹窗框架，返回内容容器供调用方填充。
-- 标题栏和右上角关闭图标由这里统一生成，因此所有页面的关闭方式保持一致。
function M.open_popup(player, title)
    M.close_popup(player)
    local frame = player.gui.screen.add{
        type = 'frame', name = M.POPUP_NAME, direction = 'vertical'}
    frame.auto_center = true

    local titlebar = frame.add{type = 'flow', direction = 'horizontal'}
    local title_label = titlebar.add{type = 'label', caption = title, style = 'frame_title'}
    title_label.drag_target = frame
    local drag_space = titlebar.add{type = 'empty-widget', style = 'draggable_space_header'}
    drag_space.style.horizontally_stretchable = true
    drag_space.style.height = 24
    drag_space.drag_target = frame
    titlebar.add{
        type = 'sprite-button', name = 'pw_close', sprite = 'utility/close',
        style = 'frame_action_button', tooltip = {'pw.close'},
    }

    local inner = frame.add{type = 'flow', name = 'inner', direction = 'vertical'}
    inner.style.width = M.WIDTH
    return inner
end

return M
