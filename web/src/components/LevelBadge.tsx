export default function LevelBadge({ level }: { level: string }) {
  return <span className={`badge level-${level}`}>{level}</span>;
}
