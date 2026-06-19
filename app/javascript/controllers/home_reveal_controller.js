import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="home-reveal"
export default class extends Controller {
  static targets = ['item', 'mock', 'navItem', 'section', 'snapTrack']

  connect () {
    this.reducedMotion = this.prefersReducedMotion()

    this.setupHeroHeading()
    this.setupHeroMockAnimation()
    this.setupConditionalBreaks()
    this.setupReveal()
    this.setupSectionNavigation()
    this.setupSectionGhosts()
    this.setupSnapIndicators()
  }

  disconnect () {
    if (this.headingTimer) {
      window.clearTimeout(this.headingTimer)
      this.headingTimer = null
    }
    this.headingTimers?.forEach((timer) => window.clearTimeout(timer))
    this.headingTimers = []
    this.mockTypingTimers?.forEach((timer) => window.clearTimeout(timer))
    this.mockTypingTimers = []
    this.snapAnimationTimers?.forEach((timer) => window.clearTimeout(timer))
    this.snapAnimationTimers = []
    this.snapHandlers?.forEach(({ track, type, handler, cleanup }) => {
      track.removeEventListener(type, handler)
      cleanup?.()
    })
    this.snapHandlers = []
    this.navHandlers?.forEach(({ link, handler }) => {
      link.removeEventListener('click', handler)
    })
    this.navHandlers = []
    this.conditionalBreakObserver?.disconnect()
    this.conditionalBreakObserver = null
    if (this.handleConditionalBreakResize) {
      window.removeEventListener('resize', this.handleConditionalBreakResize)
      this.handleConditionalBreakResize = null
    }
    this.revealObserver?.disconnect()
    this.revealObserver = null
    this.mockObserver?.disconnect()
    this.mockObserver = null
    this.sectionObserver?.disconnect()
    this.sectionObserver = null
    this.ghostObserver?.disconnect()
    this.ghostObserver = null
    this.element.classList.remove('is-grid-visible')
    this.clearSectionNavigationTimer()
    if (this.handleScrollEnd) {
      window.removeEventListener('scrollend', this.handleScrollEnd)
      this.handleScrollEnd = null
    }
    if (this.handleScroll) {
      window.removeEventListener('scroll', this.handleScroll)
    }
  }

  setupHeroHeading () {
    if (this.reducedMotion) {
      this.element.classList.add('home-lp-heading-complete')
      return
    }

    const headingVisual = this.element.querySelector('.home-hero-heading-visual')
    if (!headingVisual) return

    const units = Array.from(headingVisual.querySelectorAll('.home-hero-heading-typing-unit'))
      .map((wrapper) => {
        const textElement = wrapper.querySelector('.home-hero-heading-unit')
        const text = textElement?.dataset.homeHeadingText || textElement?.textContent || ''

        return { wrapper, textElement, text }
      })
      .filter(({ textElement, text }) => textElement && text.length > 0)

    if (units.length === 0) return

    const charDelay = this.parseTimeValue(
      window.getComputedStyle(headingVisual).getPropertyValue('--home-type-char-delay')
    )
    const completeDelay = this.parseTimeValue(
      window.getComputedStyle(headingVisual).getPropertyValue('--home-type-complete-delay')
    )

    this.headingTimers = []
    units.forEach(({ textElement }) => { textElement.textContent = '' })
    this.element.classList.add('home-lp-motion-ready')

    let delay = 120

    units.forEach(({ wrapper, textElement, text }) => {
      this.headingTimers.push(window.setTimeout(() => {
        wrapper.classList.add('is-typing')
      }, delay))

      Array.from(text).forEach((char) => {
        this.headingTimers.push(window.setTimeout(() => {
          textElement.textContent += char
        }, delay))
        delay += charDelay
      })

      this.headingTimers.push(window.setTimeout(() => {
        wrapper.classList.remove('is-typing')
      }, delay + 40))
      delay += 80
    })

    this.headingTimer = window.setTimeout(() => {
      this.element.classList.add('home-lp-heading-complete')
      this.headingTimer = null
    }, Math.max(delay, completeDelay))
  }

  setupHeroMockAnimation () {
    if (this.reducedMotion) return
    if (!this.hasMockTarget) return

    this.mockTarget.classList.add('is-ready')

    if (!('IntersectionObserver' in window)) {
      this.activateHeroMock()
      return
    }

    this.mockObserver = new window.IntersectionObserver(
      (entries) => {
        const visibleEntry = entries.find((entry) => entry.isIntersecting)

        if (!visibleEntry) return

        this.activateHeroMock()
      },
      {
        root: null,
        rootMargin: '0px 0px -16% 0px',
        threshold: 0.28
      }
    )

    this.mockObserver.observe(this.mockTarget)
  }

  activateHeroMock () {
    if (!this.hasMockTarget || this.mockTarget.classList.contains('is-active')) return

    this.mockTarget.classList.add('is-active')
    this.mockObserver?.unobserve(this.mockTarget)
    this.mockObserver?.disconnect()
    this.mockObserver = null

    this.setupHeroMockTyping()
  }

  setupHeroMockTyping () {
    if (this.reducedMotion) return

    const values = Array.from(this.element.querySelectorAll('.home-hero-typed-value'))
      .map((element) => ({
        element,
        text: element.textContent || '',
        delay: this.parseTimeValue(window.getComputedStyle(element).getPropertyValue('--home-typed-delay'))
      }))
      .filter(({ text }) => text.length > 0)

    if (values.length === 0) return

    this.mockTypingTimers = []

    values.forEach(({ element, text, delay }) => {
      element.textContent = ''

      this.mockTypingTimers.push(window.setTimeout(() => {
        element.classList.add('is-typing')

        Array.from(text).forEach((char, index) => {
          this.mockTypingTimers.push(window.setTimeout(() => {
            element.textContent += char
          }, index * 28))
        })

        this.mockTypingTimers.push(window.setTimeout(() => {
          element.classList.remove('is-typing')
        }, (text.length * 28) + 180))
      }, delay))
    })
  }

  setupConditionalBreaks () {
    this.conditionalBreakElements = Array.from(this.element.querySelectorAll('[data-home-conditional-break]'))

    if (this.conditionalBreakElements.length === 0) return

    this.handleConditionalBreakResize = () => this.updateConditionalBreaks()

    if ('ResizeObserver' in window) {
      this.conditionalBreakObserver = new window.ResizeObserver(this.handleConditionalBreakResize)
      this.conditionalBreakElements.forEach((element) => {
        this.conditionalBreakObserver.observe(element.parentElement || element)
      })
    }

    window.addEventListener('resize', this.handleConditionalBreakResize, { passive: true })
    this.updateConditionalBreaks()

    document.fonts?.ready?.then(() => {
      if (!this.element.isConnected) return

      this.updateConditionalBreaks()
    })
  }

  updateConditionalBreaks () {
    window.requestAnimationFrame(() => {
      this.conditionalBreakElements?.forEach((element) => {
        element.classList.toggle('is-wrapped', this.shouldUseConditionalBreak(element))
      })
    })
  }

  shouldUseConditionalBreak (element) {
    const container = element.parentElement
    if (!container) return false

    element.classList.remove('is-wrapped')

    const availableWidth = container.getBoundingClientRect().width
    if (availableWidth <= 0) return false

    const measuringElement = element.cloneNode(true)
    measuringElement.classList.remove('is-wrapped')
    measuringElement.setAttribute('aria-hidden', 'true')
    Object.assign(measuringElement.style, {
      display: 'inline-block',
      left: '-9999px',
      maxWidth: 'none',
      pointerEvents: 'none',
      position: 'absolute',
      top: '0',
      visibility: 'hidden',
      whiteSpace: 'nowrap',
      width: 'max-content'
    })

    container.appendChild(measuringElement)
    const requiredWidth = measuringElement.getBoundingClientRect().width
    measuringElement.remove()

    return requiredWidth > availableWidth + 1
  }

  navigate (event) {
    const sectionId = event.currentTarget.dataset.homeSectionId
    const section = sectionId ? document.getElementById(sectionId) : null

    if (!section || this.reducedMotion) return

    event.preventDefault()
    this.startProgrammaticSectionNavigation(sectionId, section)
    section.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }

  setupReveal () {
    if (this.reducedMotion || !('IntersectionObserver' in window)) {
      this.revealAll()
      return
    }

    this.element.classList.add('home-lp-reveal-ready')
    this.revealObserver = new window.IntersectionObserver(
      (entries) => this.revealVisibleEntries(entries),
      {
        root: null,
        rootMargin: '0px 0px -12% 0px',
        threshold: 0.12
      }
    )

    this.itemTargets.forEach((item) => this.revealObserver.observe(item))
  }

  setupSectionNavigation () {
    this.buildSectionNavigation()

    if (!this.hasSectionTarget || !this.hasNavItemTarget) return

    this.activateSection(this.sectionTargets[0].id)

    if (!('IntersectionObserver' in window)) return

    this.sectionObserver = new window.IntersectionObserver(
      (entries) => this.updateActiveSection(entries),
      {
        root: null,
        rootMargin: '-18% 0px -78% 0px',
        threshold: 0
      }
    )

    this.sectionTargets.forEach((section) => this.sectionObserver.observe(section))
    this.handleScroll = () => {
      this.releaseProgrammaticSectionNavigationWhenSettled()
      this.activateLastSectionAtPageEnd()
    }
    window.addEventListener('scroll', this.handleScroll, { passive: true })
    this.handleScrollEnd = () => this.finishProgrammaticSectionNavigation()
    window.addEventListener('scrollend', this.handleScrollEnd, { passive: true })
  }

  setupSectionGhosts () {
    const sections = this.sectionTargets.filter((section) => !section.classList.contains('home-hero-section'))

    if (sections.length === 0) return

    if (!('IntersectionObserver' in window)) {
      sections.forEach((section) => section.classList.add('is-ghost-visible'))
      this.element.classList.add('is-grid-visible')
      return
    }

    this.ghostObserver = new window.IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          entry.target.classList.toggle('is-ghost-visible', entry.isIntersecting)
        })

        this.updateFixedGridVisibility(sections)
      },
      {
        root: null,
        rootMargin: '-18% 0px -18% 0px',
        threshold: 0.12
      }
    )

    sections.forEach((section) => this.ghostObserver.observe(section))
  }

  updateFixedGridVisibility (sections) {
    this.element.classList.toggle(
      'is-grid-visible',
      sections.some((section) => section.classList.contains('is-ghost-visible'))
    )
  }

  buildSectionNavigation () {
    const nav = this.element.querySelector('.home-section-nav')
    if (!nav) return

    this.navHandlers?.forEach(({ link, handler }) => {
      link.removeEventListener('click', handler)
    })
    this.navHandlers = []
    nav.replaceChildren()

    this.sectionTargets
      .filter((section) => section.id && section.dataset.homeSectionLabel)
      .forEach((section, index) => {
        const label = section.dataset.homeSectionLabel
        const link = document.createElement('a')
        const labelElement = document.createElement('span')
        const handler = (event) => this.navigate(event)

        link.href = `#${section.id}`
        link.title = label
        link.className = 'home-section-nav-dot'
        link.dataset.homeRevealTarget = 'navItem'
        link.dataset.homeSectionId = section.id
        link.setAttribute('aria-label', label)

        if (index === 0) {
          link.classList.add('is-active')
          link.setAttribute('aria-current', 'true')
        }

        labelElement.className = 'sr-only'
        labelElement.textContent = label
        link.append(labelElement)
        link.addEventListener('click', handler)
        this.navHandlers.push({ link, handler })
        nav.append(link)
      })
  }

  setupSnapIndicators () {
    if (!this.hasSnapTrackTarget) return

    this.snapHandlers = []

    this.snapTrackTargets.forEach((track) => {
      const indicator = track.parentElement?.querySelector('.home-lp-snap-hint')
      if (!indicator) return

      let frame = null
      let settleTimers = []
      const cleanup = () => {
        if (frame) {
          window.cancelAnimationFrame(frame)
          frame = null
        }

        settleTimers.forEach((timer) => window.clearTimeout(timer))
        settleTimers = []
      }
      const update = () => this.updateSnapIndicator(track, indicator)
      const scheduleUpdate = () => {
        cleanup()

        frame = window.requestAnimationFrame(() => {
          update()
          frame = null
        })

        settleTimers = [80, 180, 360, 700].map((delay) => window.setTimeout(update, delay))
      }

      track.addEventListener('scroll', scheduleUpdate, { passive: true })
      track.addEventListener('scrollend', update, { passive: true })
      track.addEventListener('touchcancel', scheduleUpdate, { passive: true })
      track.addEventListener('touchend', scheduleUpdate, { passive: true })
      track.addEventListener('pointerup', scheduleUpdate, { passive: true })
      this.snapHandlers.push({ track, type: 'scroll', handler: scheduleUpdate, cleanup })
      this.snapHandlers.push({ track, type: 'scrollend', handler: update })
      this.snapHandlers.push({ track, type: 'touchcancel', handler: scheduleUpdate })
      this.snapHandlers.push({ track, type: 'touchend', handler: scheduleUpdate })
      this.snapHandlers.push({ track, type: 'pointerup', handler: scheduleUpdate })
      window.requestAnimationFrame(update)
    })
  }

  updateSnapIndicator (track, indicator) {
    const cards = Array.from(track.querySelectorAll('.home-lp-card'))
    const dots = Array.from(indicator.children)

    if (cards.length === 0 || dots.length === 0) return

    const resolvedIndex = this.resolveSnapIndex(track, cards)
    const activeIndex = Math.max(0, Math.min(resolvedIndex, dots.length - 1))
    const activeDot = dots[activeIndex]
    const previousActiveIndex = indicator.dataset.activeIndex
    const activeChanged = previousActiveIndex !== undefined && previousActiveIndex !== String(activeIndex)

    indicator.dataset.activeIndex = String(activeIndex)
    indicator.style.setProperty('--home-snap-active-offset', `${activeDot?.offsetLeft || 0}px`)
    dots.forEach((dot) => dot.classList.remove('is-active'))
    activeDot?.classList.add('is-active')

    if (activeChanged) this.animateSnapIndicator(indicator)
  }

  animateSnapIndicator (indicator) {
    if (this.reducedMotion) return

    indicator.classList.remove('is-changing')

    window.requestAnimationFrame(() => {
      indicator.classList.add('is-changing')

      const timer = window.setTimeout(() => {
        indicator.classList.remove('is-changing')
        this.snapAnimationTimers = this.snapAnimationTimers?.filter((snapTimer) => snapTimer !== timer)
      }, 280)

      this.snapAnimationTimers ||= []
      this.snapAnimationTimers.push(timer)
    })
  }

  resolveSnapIndex (track, cards) {
    const maxScrollLeft = Math.max(0, track.scrollWidth - track.clientWidth)
    const scrollLeft = Math.max(0, Math.min(track.scrollLeft, maxScrollLeft))
    const edgeThreshold = 2

    if (scrollLeft <= edgeThreshold) return 0
    if (scrollLeft >= maxScrollLeft - edgeThreshold) return cards.length - 1

    const trackRect = track.getBoundingClientRect()
    const trackCenter = trackRect.left + (trackRect.width / 2)

    return cards.reduce((closestIndex, card, index) => {
      const cardRect = card.getBoundingClientRect()
      const cardCenter = cardRect.left + (cardRect.width / 2)
      const currentDistance = Math.abs(cardCenter - trackCenter)
      const closestCardRect = cards[closestIndex].getBoundingClientRect()
      const closestCenter = closestCardRect.left + (closestCardRect.width / 2)
      const closestDistance = Math.abs(closestCenter - trackCenter)

      return currentDistance < closestDistance ? index : closestIndex
    }, 0)
  }

  revealVisibleEntries (entries) {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return

      this.reveal(entry.target)
    })
  }

  reveal (item) {
    item.classList.add('is-revealed')
    this.revealObserver?.unobserve(item)
  }

  revealAll () {
    this.itemTargets.forEach((item) => item.classList.add('is-revealed'))
  }

  updateActiveSection (entries) {
    if (this.programmaticSectionId) return

    const visibleEntry = entries
      .filter((entry) => entry.isIntersecting)
      .sort((first, second) => second.intersectionRatio - first.intersectionRatio)[0]

    if (!visibleEntry) return

    this.activateSection(visibleEntry.target.id)
  }

  activateSection (sectionId) {
    this.navItemTargets.forEach((item) => {
      const isActive = item.dataset.homeSectionId === sectionId

      item.classList.toggle('is-active', isActive)

      if (isActive) {
        item.setAttribute('aria-current', 'true')
      } else {
        item.removeAttribute('aria-current')
      }
    })
  }

  startProgrammaticSectionNavigation (sectionId, section) {
    this.programmaticSectionId = sectionId
    this.activateSection(sectionId)
    this.clearSectionNavigationTimer()
    this.sectionNavigationTimer = window.setTimeout(
      () => this.finishProgrammaticSectionNavigation(),
      this.resolveSectionNavigationTimeout(section)
    )
  }

  finishProgrammaticSectionNavigation () {
    if (!this.programmaticSectionId) return

    const sectionId = this.programmaticSectionId

    this.programmaticSectionId = null
    this.clearSectionNavigationTimer()
    this.activateSection(sectionId)
  }

  releaseProgrammaticSectionNavigationWhenSettled () {
    if (!this.programmaticSectionId) return

    const section = document.getElementById(this.programmaticSectionId)
    if (!section) {
      this.finishProgrammaticSectionNavigation()
      return
    }

    const targetTop = Math.abs(section.getBoundingClientRect().top)
    const documentElement = document.documentElement
    const distanceToBottom = documentElement.scrollHeight - (window.scrollY + window.innerHeight)
    const isLastSection = this.sectionTargets[this.sectionTargets.length - 1]?.id === this.programmaticSectionId

    if (targetTop <= 3 || (isLastSection && distanceToBottom <= 8)) {
      this.finishProgrammaticSectionNavigation()
    }
  }

  clearSectionNavigationTimer () {
    if (!this.sectionNavigationTimer) return

    window.clearTimeout(this.sectionNavigationTimer)
    this.sectionNavigationTimer = null
  }

  resolveSectionNavigationTimeout (section) {
    const distance = Math.abs(section.getBoundingClientRect().top)

    return Math.min(1800, Math.max(700, distance * 0.35))
  }

  activateLastSectionAtPageEnd () {
    if (this.programmaticSectionId) return

    const documentElement = document.documentElement
    const distanceToBottom = documentElement.scrollHeight - (window.scrollY + window.innerHeight)

    if (distanceToBottom > 8) return

    const lastSection = this.sectionTargets[this.sectionTargets.length - 1]

    if (lastSection) this.activateSection(lastSection.id)
  }

  prefersReducedMotion () {
    return window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
  }

  parseTimeValue (value) {
    const numericValue = Number.parseFloat(value)

    if (!Number.isFinite(numericValue)) return 0

    return value.trim().endsWith('s') && !value.trim().endsWith('ms') ? numericValue * 1000 : numericValue
  }
}
