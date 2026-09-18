import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Waffles',
  description: 'Dependency-free, high-performance binary serialization for Roblox Luau.',
  // Project Pages URL: https://sudo-sleep-now.github.io/Waffles/
  base: '/Waffles/',
  appearance: 'force-dark',
  cleanUrls: true,
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/Waffles/waffle.svg' }],
    ['meta', { name: 'theme-color', content: '#14100b' }],
  ],

  themeConfig: {
    logo: '/waffle.svg',
    siteTitle: 'Waffles',
    outline: [2, 3],

    nav: [
      { text: 'Guide', link: '/guide/introduction' },
      { text: 'Reference', link: '/reference/configuration' },
      { text: 'Benchmarks', link: '/benchmarks' },
      { text: 'Releases', link: '/releases' },
      { text: 'API', link: '/reference/api' },
    ],

    socialLinks: [{ icon: 'github', link: 'https://github.com/sudo-sleep-now/Waffles' }],

    sidebar: {
      '/guide/': [
        {
          text: 'Getting started',
          items: [
            { text: 'Introduction', link: '/guide/introduction' },
            { text: 'Installation', link: '/guide/installation' },
            { text: 'Quick start', link: '/guide/quick-start' },
          ],
        },
        {
          text: 'Core concepts',
          items: [
            { text: 'Automatic serialization', link: '/guide/automatic' },
            { text: 'Supported types', link: '/guide/supported-types' },
            { text: 'Schemas', link: '/guide/schemas' },
            { text: 'Smart schemas', link: '/guide/smart-schemas' },
            { text: 'Batch serialization', link: '/guide/batch' },
            { text: 'Custom converters', link: '/guide/converters' },
            { text: 'Buffer helpers', link: '/guide/buffer-helpers' },
          ],
        },
        {
          text: 'Cookbook',
          items: [
            { text: 'Examples', link: '/guide/examples' },
            { text: 'Troubleshooting', link: '/guide/troubleshooting' },
          ],
        },
      ],
      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'Configuration', link: '/reference/configuration' },
            { text: 'Networking', link: '/reference/networking' },
            { text: 'Wire format & security', link: '/reference/wire-security' },
            { text: 'Performance notes', link: '/reference/performance' },
            { text: 'API reference', link: '/reference/api' },
            { text: 'Tests & benchmarks', link: '/reference/tests' },
          ],
        },
      ],
      '/': [
        {
          text: 'Waffles',
          items: [
            { text: 'Home', link: '/' },
            { text: 'Introduction', link: '/guide/introduction' },
            { text: 'Benchmarks vs Pancakes', link: '/benchmarks' },
            { text: 'Releases', link: '/releases' },
            { text: 'API reference', link: '/reference/api' },
          ],
        },
      ],
    },

    search: { provider: 'local' },

    footer: {
      message: 'MIT License · Wire v2 · Dependency-free · Native buffer output',
      copyright: '© Waffles',
    },
  },
})
