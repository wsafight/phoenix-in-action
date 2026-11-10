// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
  site: 'https://wsafight.github.io',
  base: '/phoenix-in-action',
  integrations: [
    starlight({
      title: 'Auction：一个 Phoenix 应用的成长史',
      description:
        '跟着 11 个可运行的代码快照，用 Phoenix 1.7 把一个拍卖应用从零养大：领域层 → umbrella → Web → Ecto → CRUD → 认证 → 出价 → Channel → JSON API。',
      defaultLocale: 'root',
      locales: {
        root: { label: '简体中文', lang: 'zh-CN' },
      },
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/wsafight/phoenix-in-action',
        },
      ],
      sidebar: [
        { label: '导读', slug: 'index' },
        { label: '正文', autogenerate: { directory: 'chapters' } },
        { label: '附录', autogenerate: { directory: 'appendix' } },
      ],
      customCss: ['./src/styles/custom.css'],
    }),
  ],
});
