'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require dom';

var status = rpc.declare({ object: 'kokawu.upgrade', method: 'status', expect: { '': {} }, reject: true });
var check = rpc.declare({ object: 'kokawu.upgrade', method: 'check', expect: { '': {} }, reject: true });
var upgrade = rpc.declare({ object: 'kokawu.upgrade', method: 'upgrade', params: ['version', 'keep'], expect: { '': {} }, reject: true });
var active = ['checking', 'downloading', 'verifying', 'upgrading'];
function setText(node, value) { dom.content(node, [String(value)]); }

return view.extend({
    load: function() { return status(); },

    update: function(s) {
        this.data = s;
        var c = s.current || {}, n = s.latest || {};
        setText(this.currentNode, c.version || '无法读取当前固件标识');
        setText(this.latestNode, n.version || '尚未检查');
        setText(this.typeNode, [c.target || '未知', s.boot || '未知启动方式', c.filesystem || '未知', c.layout || ''].join(' / '));
        setText(this.timeNode, s.checked_at ? new Date(s.checked_at * 1000).toLocaleString() : '尚未成功检查');
        setText(this.messageNode, s.message || '');
        dom.content(this.notesNode, n.version && /^(online-\d+-\d+|\d{4}\.\d{2}\.\d{2}-\d{2,})$/.test(n.version) ?
            E('a', { href: 'https://github.com/kokawu/immortalwrt/releases/tag/' + (n.version.indexOf('online-') === 0 ? n.version : 'v' + n.version), target: '_blank', rel: 'noopener noreferrer' }, '查看版本说明和源码提交') : '—');
        var busy = this.pending || active.indexOf(s.state) >= 0 || !L.hasViewPermission();
        this.checkButton.disabled = !!busy;
        this.upgradeButton.disabled = !!busy || !s.available;
    },

    refresh: function() {
        return status().then(this.update.bind(this)).catch(function(err) {
            var rebooting = this.data && this.data.state === 'upgrading';
            setText(this.messageNode, rebooting ?
                '设备正在升级或重启，暂时无法连接。请勿断电；若未保留配置，请使用新固件默认地址重新登录。' :
                '无法读取升级状态：' + err.message);
            this.checkButton.disabled = this.upgradeButton.disabled = true;
        }.bind(this));
    },

    request: function(call) {
        this.pending = true;
        this.update(this.data);
        return call().then(function(result) {
            if (!result.accepted) throw new Error(result.message || '请求被拒绝');
            return this.refresh();
        }.bind(this)).catch(function(err) {
            ui.addNotification(null, E('p', {}, [err.message]), 'error');
        }).finally(function() {
            this.pending = false;
            this.update(this.data);
        }.bind(this));
    },

    confirmUpgrade: function() {
        var version = this.data.latest && this.data.latest.version;
        if (!version || !this.data.available) return;
        var keep = E('input', { type: 'checkbox', checked: 'checked' });
        ui.showModal('确认在线升级', [
            E('p', {}, ['目标版本：' + version]),
            E('p', {}, '固件将直接下载到路由器，校验通过后升级并重启。期间网络会中断，请勿断电。'),
            E('p', {}, '保留配置不等于保留后来安装的软件。建议先下载配置备份；清除配置后需要通过新固件默认地址重新登录。'),
            E('label', { class: 'cbi-value' }, [keep, ' 保留当前配置']),
            E('div', { class: 'right' }, [
                E('button', { class: 'btn', click: ui.hideModal }, '取消'),
                ' ',
                E('button', { class: 'btn cbi-button-negative', click: function() {
                    var preserve = keep.checked;
                    ui.hideModal();
                    return this.request(function() { return upgrade(version, preserve); });
                }.bind(this) }, '确认下载并升级')
            ])
        ]);
    },

    render: function(data) {
        this.currentNode = E('span');
        this.latestNode = E('span');
        this.typeNode = E('span');
        this.timeNode = E('span');
        this.messageNode = E('p', { style: 'white-space: pre-wrap' });
        this.notesNode = E('span');
        this.checkButton = E('button', { class: 'btn cbi-button-action', click: function() {
            return this.request(check);
        }.bind(this) }, '检查新版');
        this.upgradeButton = E('button', { class: 'btn cbi-button-positive', click: this.confirmUpgrade.bind(this) }, '下载并升级');
        function row(label, value) {
            return E('div', { class: 'cbi-value' }, [
                E('label', { class: 'cbi-value-title' }, label),
                E('div', { class: 'cbi-value-field' }, [value])
            ]);
        }
        var page = E('div', { class: 'cbi-map' }, [
            E('h2', {}, '在线升级'),
            E('p', {}, '仅从 kokawu/immortalwrt 的 stable 渠道检查与当前设备匹配的固件。每天只检查版本，不会自动下载或刷机。'),
            row('当前版本', this.currentNode), row('最新版本', this.latestNode),
            row('设备与镜像类型', this.typeNode), row('上次成功检查', this.timeNode),
            row('更新说明', this.notesNode),
            this.messageNode,
            E('p', {}, [E('a', { href: L.url('admin/system/flash'), target: '_blank', rel: 'noopener noreferrer' }, '先前往“备份／升级”下载配置备份')]),
            E('div', { class: 'cbi-page-actions' }, [this.checkButton, ' ', this.upgradeButton])
        ]);
        this.update(data);
        poll.add(this.refresh.bind(this), 3);
        return page;
    },
    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
