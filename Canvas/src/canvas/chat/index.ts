/**
 * The one chat hub, following the controller's session: a new `init` hands
 * it the new document, a status change lets it settle the read mark.
 */
import { controller } from '../../controller'
import { ChatHub } from './hub'

export const chat = new ChatHub(fn => controller.subscribe(fn))

// Checklist assignees: the people they are picked from, whom an agent's
// `assignees` resolve against, and the notification a new one gets.
chat.showCard = id => controller.zoomTo([id])
controller.opsHooks = {
  people: () => chat.people(),
  onAssigned: e => void chat.notifyAssigned(e),
}

let attached: unknown = undefined
controller.subscribe(() => {
  if (controller.session !== attached) {
    attached = controller.session
    chat.attach(controller.session)
  }
})

export type { ChatPageMessage } from './bridge'
