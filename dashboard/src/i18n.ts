import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import { i18nLng } from './lib/locale'

// English + Simplified Chinese only. Keys are flat; interpolation via {{...}}.
// Date/time formatting is locale-aware via Intl (see lib/format.ts), not here.
const resources = {
  en: {
    translation: {
      'range.today': 'Today',
      'range.week': 'This Week',
      'range.month': 'This Month',
      'range.custom': 'Custom…',
      refresh: 'Refresh',
      loading: 'Loading…',
      header_total: '{{count}} segments · {{duration}}',
      total: 'Total',
      no_activity: 'No activity in this range',
      'tab.segments': 'Segments',
      'tab.summary': 'By Client / Project',
      segments_unit: 'segments',
      page_of: 'Page {{page}} / {{total}}',
      prev: 'Prev',
      next: 'Next',
      'col.start': 'Start',
      'col.duration': 'Duration',
      'col.source': 'Source',
      'col.project': 'Project',
      'col.client': 'Client',
      'col.title': 'Title',
      'col.billable': 'Billable',
      no_segments: 'No segments',
      billable: 'billable',
      unassigned: 'Unassigned',
      no_project: 'No project',
      no_data: 'No data',
    },
  },
  'zh-Hans': {
    translation: {
      'range.today': '今天',
      'range.week': '本周',
      'range.month': '本月',
      'range.custom': '自定义…',
      refresh: '刷新',
      loading: '加载中…',
      header_total: '{{count}} 个区段 · {{duration}}',
      total: '总计',
      no_activity: '该区间内无活动',
      'tab.segments': '区段',
      'tab.summary': '按客户 / 项目',
      segments_unit: '区段',
      page_of: '第 {{page}} / {{total}} 页',
      prev: '上一页',
      next: '下一页',
      'col.start': '开始',
      'col.duration': '时长',
      'col.source': '来源',
      'col.project': '项目',
      'col.client': '客户',
      'col.title': '标题',
      'col.billable': '计费',
      no_segments: '暂无区段',
      billable: '可计费',
      unassigned: '未分配客户',
      no_project: '未指定项目',
      no_data: '暂无数据',
    },
  },
} as const

void i18n.use(initReactI18next).init({
  resources,
  lng: i18nLng(),
  fallbackLng: 'en',
  interpolation: { escapeValue: false },
})

export default i18n
