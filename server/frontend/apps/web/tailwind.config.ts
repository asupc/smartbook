import type { Config } from 'tailwindcss'

const config: Config = {
  darkMode: ['class'],
  content: [
    './index.html',
    './src/**/*.{ts,tsx}',
    '../../packages/ui/src/**/*.{ts,tsx}',
    '../../packages/web-features/src/**/*.{ts,tsx}'
  ],
  theme: {
    extend: {
      colors: {
        border: 'hsl(var(--border))',
        input: 'hsl(var(--input))',
        ring: 'hsl(var(--ring))',
        background: 'hsl(var(--background))',
        foreground: 'hsl(var(--foreground))',
        primary: {
          DEFAULT: 'hsl(var(--primary))',
          foreground: 'hsl(var(--primary-foreground))'
        },
        secondary: {
          DEFAULT: 'hsl(var(--secondary))',
          foreground: 'hsl(var(--secondary-foreground))'
        },
        muted: {
          DEFAULT: 'hsl(var(--muted))',
          foreground: 'hsl(var(--muted-foreground))'
        },
        accent: {
          DEFAULT: 'hsl(var(--accent))',
          foreground: 'hsl(var(--accent-foreground))'
        },
        destructive: {
          DEFAULT: 'hsl(var(--destructive))',
          foreground: 'hsl(var(--destructive-foreground))'
        },
        card: {
          DEFAULT: 'hsl(var(--card))',
          foreground: 'hsl(var(--card-foreground))'
        },
        popover: {
          DEFAULT: 'hsl(var(--popover))',
          foreground: 'hsl(var(--popover-foreground))'
        },
        // 收支语义色：跟 mobile `incomeExpenseColorSchemeProvider` 同步，
        // 通过 <html data-income-color="red|green"> 切换底层 CSS var。
        income: 'rgb(var(--income-rgb) / <alpha-value>)',
        expense: 'rgb(var(--expense-rgb) / <alpha-value>)'
      },
      borderRadius: {
        lg: 'var(--radius)',
        md: 'calc(var(--radius) - 2px)',
        sm: 'calc(var(--radius) - 4px)'
      },
      boxShadow: {
        soft: '0 10px 30px -16px hsl(var(--shadow) / 0.55)'
      },
      keyframes: {
        // DialogContent 抽屉化(@smartbook/ui dialog.tsx):右侧滑入/滑出 +
        // 遮罩淡入淡出。cubic-bezier 与 antd Drawer 默认曲线一致。
        'drawer-in': {
          '0%': { transform: 'translateX(100%)' },
          '100%': { transform: 'translateX(0)' }
        },
        'drawer-out': {
          '0%': { transform: 'translateX(0)' },
          '100%': { transform: 'translateX(100%)' }
        },
        'fade-in': {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' }
        },
        'fade-out': {
          '0%': { opacity: '1' },
          '100%': { opacity: '0' }
        }
      },
      animation: {
        'drawer-in': 'drawer-in 260ms cubic-bezier(0.32, 0.72, 0, 1)',
        'drawer-out': 'drawer-out 200ms cubic-bezier(0.32, 0.72, 0, 1) forwards',
        'fade-in': 'fade-in 200ms ease-out',
        'fade-out': 'fade-out 160ms ease-in forwards'
      }
    }
  },
  plugins: []
}

export default config
