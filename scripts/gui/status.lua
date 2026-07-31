-- 合并「领取 / 兑换 / 经验」为一个窗口。
--
-- 原来是三个独立弹窗（claim.lua / convert.lua / exp.lua 各自 M.show 开一个），
-- 玩家要点三次才看全自己的状态。现在这三个模块只导出 M.render(container, player)，
-- 往传进去的容器里画自己那一段内容，不再各自 open_popup——本模块负责开唯一的一个弹窗、
-- 依次调用三段渲染、加分隔线，并把点击转发给对应的子模块。单一职责没变，只是不再各开各的窗口。
--
-- 顶层只 require popup（叶子模块）和三个内容模块，不 require gui.init：
-- init.lua 要反过来 require 本模块来路由 HUD 按钮点击，形成循环的话 Factorio 又不允许用
-- 函数体内 require 绕开，只能从依赖图上避免这条边。
local popup = require('scripts.gui.popup')
local claim = require('scripts.gui.claim')
local convert = require('scripts.gui.convert')
local exp_window = require('scripts.gui.exp')

local M = {}

function M.show(player)
    local inner = popup.open_popup(player, {'pw.status-title'})

    -- 三段内容共用一个滚动容器：经验表有 12 行，加上体力池和兑换预览，
    -- 内容总高度很容易超过屏幕，用 scroll-pane 让弹窗本身不会被撑爆。
    -- 宽度显式钉在 popup.WIDTH（减去滚动条那点边距），跟其它弹窗保持一致的观感。
    local scroll = inner.add{type = 'scroll-pane', name = 'pw_status_scroll', direction = 'vertical'}
    scroll.style.width = popup.WIDTH - 12
    scroll.style.maximal_height = 640

    claim.render(scroll, player)
    scroll.add{type = 'line', direction = 'horizontal'}
    convert.render(scroll, player)
    scroll.add{type = 'line', direction = 'horizontal'}
    exp_window.render(scroll, player)
end

-- 三段各自处理自己按钮的点击；谁认领了这次点击，就在这里统一重开整个窗口——
-- 领取/兑换都会连带改变另外两段要显示的数字（体力、经验、兑换预览），
-- 不重开整个窗口的话，玩家点完看到的会是过期数据。
function M.on_click(player, name)
    if claim.on_click(player, name) then
        M.show(player)
        return true
    end
    if convert.on_click(player, name) then
        M.show(player)
        return true
    end
    return false
end

return M
