-- GUI 的公共骨架：弹窗容器和名字常量。
--
-- 单独成一个【叶子模块】（不 require 任何东西）是有意的：
-- 五个窗口模块和 init.lua 都要用这些辅助，若把它们留在 init.lua 里，
-- 子模块就得反过来 require init，形成循环依赖。
-- Factorio 又禁止在函数体内 require（只能在模块顶层），所以那种循环无法绕开，
-- 只能从依赖图上消掉 —— 抽成叶子模块就是消掉它的办法。
local M = {}

M.HUD_NAME = 'pw_hud'
M.POPUP_NAME = 'pw_popup'

-- 关掉可能已存在的弹窗，保证同时只有一个，不会叠罗汉
function M.close_popup(player)
    local existing = player.gui.screen[M.POPUP_NAME]
    if existing then existing.destroy() end
end

-- 建一个居中的空弹窗框架，返回内容容器供调用方填充
function M.open_popup(player, title)
    M.close_popup(player)
    local frame = player.gui.screen.add{
        type = 'frame', name = M.POPUP_NAME, caption = title, direction = 'vertical'}
    frame.auto_center = true
    local inner = frame.add{type = 'flow', name = 'inner', direction = 'vertical'}
    frame.add{type = 'button', name = 'pw_close', caption = {'pw.close'}}
    return inner
end

return M
