import { useMemo } from 'react'
import { ArrowUpRight, BookOpen, Cloud, Github, Heart, Smartphone } from 'lucide-react'

import { Drawer } from 'antd'
import { useT } from '@smartbook/ui'

/**
 * 「关于 SmartBook」弹窗 —— 致敬原作者 + 上游项目仓库入口。
 *
 * 二开版本不再展示「当前版本 vs 最新 release」对比与 release 列表(本地产
 * 品版本与上游版本号不可直接比较,对比只会误导),改为向原作者 TNT-Likely
 * 致以谢意,并保留上游仓库外链供用户溯源。
 */

const REPO_OWNER = 'TNT-Likely'
const REPO_CLOUD = 'BeeCount-Cloud' // 上游仓库名(外链数据源,勿改,会进入 GitHub URL)
const REPO_APP = 'BeeCount' // 同上:客户端上游仓库名
const REPO_DOCS = 'BeeCount-Website'

interface Props {
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function AboutDialog({ open, onOpenChange }: Props) {
  const t = useT()

  const repos = useMemo(
    () => [
      {
        key: 'app',
        icon: Smartphone,
        title: t('about.repos.app.title'),
        desc: t('about.repos.app.desc'),
        url: `https://github.com/${REPO_OWNER}/${REPO_APP}`,
      },
      {
        key: 'cloud',
        icon: Cloud,
        title: t('about.repos.cloud.title'),
        desc: t('about.repos.cloud.desc'),
        url: `https://github.com/${REPO_OWNER}/${REPO_CLOUD}`,
      },
      {
        key: 'docs',
        icon: BookOpen,
        title: t('about.repos.docs.title'),
        desc: t('about.repos.docs.desc'),
        url: `https://github.com/${REPO_OWNER}/${REPO_DOCS}`,
      },
    ],
    [t],
  )

  return (
    <Drawer
      open={open}
      onClose={() => onOpenChange(false)}
      title={t('about.title')}
      width={672}
      footer={null}
      styles={{ body: { overflowY: 'auto' } }}
    >
      {/* 致敬原作者 */}
      <div className="flex flex-col items-center gap-2.5 rounded-xl border border-border/60 bg-muted/30 px-6 py-5 text-center">
        <Heart className="h-5 w-5 fill-red-500/20 text-red-500" />
        <span className="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
          {t('about.credit.title')}
        </span>
        <p className="max-w-md text-[12px] leading-relaxed text-muted-foreground">
          {t('about.credit.text')}
        </p>
        <a
          href={`https://github.com/${REPO_OWNER}`}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1 text-[12px] font-medium text-primary hover:underline"
        >
          @{REPO_OWNER}
          <ArrowUpRight className="h-3 w-3" />
        </a>
      </div>

      {/* 项目仓库 —— 三栏卡片,点击外链 */}
      <div className="mt-4">
        <div className="mb-1.5 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
          <Github className="h-3 w-3" />
          {t('about.reposHeader')}
        </div>
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
          {repos.map(({ key, icon: Icon, title, desc, url }) => (
            <a
              key={key}
              href={url}
              target="_blank"
              rel="noopener noreferrer"
              className="group flex flex-col gap-1 rounded-lg border border-border/50 bg-card px-3 py-2.5 transition hover:border-primary/40 hover:bg-primary/5"
            >
              <div className="flex items-center gap-1.5">
                <Icon className="h-3.5 w-3.5 text-primary" />
                <span className="text-[12px] font-semibold text-foreground">
                  {title}
                </span>
                <ArrowUpRight className="ml-auto h-3 w-3 text-muted-foreground opacity-0 transition group-hover:opacity-100" />
              </div>
              <p className="text-[11px] leading-snug text-muted-foreground">
                {desc}
              </p>
            </a>
          ))}
        </div>
      </div>
    </Drawer>
  )
}
