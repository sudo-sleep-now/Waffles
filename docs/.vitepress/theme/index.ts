import DefaultTheme from 'vitepress/theme'
import './custom.css'
import BenchmarkDashboard from './components/BenchmarkDashboard.vue'
import LatestRelease from './components/LatestRelease.vue'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('BenchmarkDashboard', BenchmarkDashboard)
    app.component('LatestRelease', LatestRelease)
  },
}
