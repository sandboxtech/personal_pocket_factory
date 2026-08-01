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

    -- 三段各自装进一个内嵌 frame，而不是拿一条 line 隔开。
    -- 一条横线只是"这里断了一下"，三块下沉的面板才能让人一眼看出这是三件独立的事
    -- （攒体力 / 花体力换经验 / 看经验攒到哪了）。中间那段还有一张兑换预览表，
    -- 没有边框的话它和上下两段的行会糊成一片。
    local function section()
        local frame = scroll.add{type = 'frame', style = 'inside_shallow_frame_with_padding',
                                 direction = 'vertical'}
        frame.style.horizontally_stretchable = true
        frame.style.bottom_margin = 4
        return frame
    end

    claim.render(section(), player)
    convert.render(section(), player)
    exp_window.render(section(), player)
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
